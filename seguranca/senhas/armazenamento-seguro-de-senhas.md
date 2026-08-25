# Armazenamento seguro de senhas — e como migrar de um hash legado

> O que usar hoje, por que MD5 e SHA-1 continuam aparecendo em bancos de produção, e como trocar
> o algoritmo sem pedir que 200 mil usuários redefinam a senha.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.7.2+ e .NET Core/5+. `RandomNumberGenerator.GetBytes(int)` exige .NET 6+; há alternativa para versões anteriores. |
| **Impacto** | A migração altera a tabela de usuários. Requer backup e janela planejada. |

---

## Problema

Senha não se guarda. Guarda-se uma prova de que quem digitou conhece a senha — e essa prova
precisa ser cara de reverter.

Os erros que ainda aparecem em sistemas em produção:

| Prática encontrada | Por que é grave |
|---|---|
| Senha em texto claro | Um `SELECT` na tabela entrega todas as contas |
| Senha criptografada (reversível) | A chave está na aplicação. Quem tem o banco costuma ter o código |
| MD5 ou SHA-1 sem salt | Hardware comum testa bilhões por segundo; rainbow tables resolvem o resto |
| SHA-256 sem salt | Igualmente rápido. Função de hash rápida é exatamente o que não se quer aqui |
| Salt único para todos | Anula o propósito do salt: uma tabela serve para toda a base |
| Comparar com `==` | Vaza informação por tempo de resposta |

O ponto central: **funções de hash de propósito geral são rápidas por design.** Para senha,
lentidão é requisito, não defeito.

---

## O que usar

Recomendação do OWASP, em ordem de preferência:

| Algoritmo | Parâmetros mínimos recomendados | Observação |
|---|---|---|
| **Argon2id** | m = 19 MiB, t = 2, p = 1 | Primeira escolha. Resistente a ataque com GPU e ASIC |
| **scrypt** | N = 2^17, r = 8, p = 1 | Alternativa quando Argon2 não está disponível |
| **bcrypt** | work factor ≥ 10 | Sistemas legados. **Limite de 72 bytes** na senha |
| **PBKDF2-HMAC-SHA256** | 600.000 iterações | Quando há exigência de conformidade FIPS-140 |
| PBKDF2-HMAC-SHA512 | 220.000 iterações | — |

No ecossistema .NET, a escolha pragmática costuma ser **PBKDF2**, porque está na biblioteca padrão
(`Rfc2898DeriveBytes`) e não adiciona dependência. Argon2id exige pacote de terceiros.

---

## Solução A — ASP.NET Core Identity (prefira esta)

Se a aplicação usa ASP.NET Core, **não escreva o seu próprio**. O `PasswordHasher<TUser>` do
Identity implementa PBKDF2-HMAC-SHA256 com salt aleatório por senha, formato versionado e
comparação em tempo constante.

```csharp
// Configuracao
services.Configure<PasswordHasherOptions>(opcoes =>
{
    opcoes.CompatibilityMode = PasswordHasherCompatibilityMode.IdentityV3;
    opcoes.IterationCount    = 600_000;   // padrao e 100_000; OWASP recomenda 600_000
});
```

```csharp
// Uso direto, mesmo fora do Identity completo
private readonly IPasswordHasher<Usuario> _hasher;

public string GerarHash(Usuario usuario, string senha)
    => _hasher.HashPassword(usuario, senha);

public bool Verificar(Usuario usuario, string senhaDigitada)
{
    var resultado = _hasher.VerifyHashedPassword(
        usuario, usuario.SenhaHash, senhaDigitada);

    return resultado is PasswordVerificationResult.Success
                     or PasswordVerificationResult.SuccessRehashNeeded;
}
```

`SuccessRehashNeeded` é o detalhe que faz esse tipo funcionar bem no longo prazo: a senha está
correta, mas foi gerada com parâmetros antigos. É o gancho para regravar o hash com o custo atual,
no momento do login — sem incomodar o usuário.

```csharp
if (resultado == PasswordVerificationResult.SuccessRehashNeeded)
{
    usuario.SenhaHash = _hasher.HashPassword(usuario, senhaDigitada);
    await _repositorio.AtualizarAsync(usuario, cancellationToken);
}
```

> **Aumentar `IterationCount` custa CPU no servidor.** 600.000 iterações multiplicam o custo por
> seis em relação ao padrão. Em endpoint de login exposto, isso é também um vetor de negação de
> serviço — acompanhe de limitação de taxa por IP e por conta. Meça o tempo de resposta antes de
> escolher o número.

---

## Solução B — PBKDF2 sem Identity (.NET Framework ou aplicação sem Identity)

Quando não há Identity disponível, o padrão abaixo cobre os requisitos: salt por senha, algoritmo
explícito, formato versionado e comparação em tempo constante.

```csharp
using System;
using System.Security.Cryptography;

public static class HashDeSenha
{
    private const int TamanhoSalt   = 16;       // 128 bits
    private const int TamanhoHash   = 32;       // 256 bits
    private const int Iteracoes     = 600_000;  // OWASP para PBKDF2-HMAC-SHA256
    private const char Separador    = '$';
    private const string Versao     = "pbkdf2-sha256-v1";

    public static string Gerar(string senha)
    {
        if (string.IsNullOrEmpty(senha))
            throw new ArgumentException("Senha vazia.", nameof(senha));

        // .NET 6+
        var salt = RandomNumberGenerator.GetBytes(TamanhoSalt);

        // .NET Framework / .NET Core anterior ao 6:
        // var salt = new byte[TamanhoSalt];
        // using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(salt);

        var hash = Derivar(senha, salt, Iteracoes);

        // O formato guarda os parametros. Sem isso, mudar o custo no futuro
        // invalida todos os hashes existentes.
        return string.Join(Separador,
            Versao,
            Iteracoes.ToString(),
            Convert.ToBase64String(salt),
            Convert.ToBase64String(hash));
    }

    public static bool Verificar(string senhaDigitada, string hashArmazenado,
                                 out bool precisaRegravar)
    {
        precisaRegravar = false;

        if (string.IsNullOrEmpty(hashArmazenado))
            return false;

        var partes = hashArmazenado.Split(Separador);
        if (partes.Length != 4 || partes[0] != Versao)
            return false;

        if (!int.TryParse(partes[1], out var iteracoesArmazenadas))
            return false;

        var salt         = Convert.FromBase64String(partes[2]);
        var hashEsperado = Convert.FromBase64String(partes[3]);

        var hashCalculado = Derivar(senhaDigitada, salt, iteracoesArmazenadas);

        // Comparacao em tempo constante: nao vaza informacao pelo tempo gasto.
        var confere = CryptographicOperations.FixedTimeEquals(hashCalculado, hashEsperado);

        if (confere && iteracoesArmazenadas < Iteracoes)
            precisaRegravar = true;

        return confere;
    }

    private static byte[] Derivar(string senha, byte[] salt, int iteracoes)
    {
        using var derivacao = new Rfc2898DeriveBytes(
            senha, salt, iteracoes, HashAlgorithmName.SHA256);

        return derivacao.GetBytes(TamanhoHash);
    }
}
```

### Por que cada peça está ali

- **Salt aleatório de 16 bytes por senha.** Duas contas com a mesma senha produzem hashes
  diferentes. O salt não é segredo — é guardado junto — e não precisa ser.
- **`HashAlgorithmName.SHA256` explícito.** A sobrecarga de `Rfc2898DeriveBytes` sem esse
  parâmetro usa **SHA-1**, por compatibilidade histórica. Omitir é um erro silencioso.
- **`CryptographicOperations.FixedTimeEquals`.** Comparação normal de arrays retorna na primeira
  diferença; medindo o tempo de resposta, um atacante descobre o hash byte a byte. Disponível a
  partir do .NET Core 2.1 e do .NET Framework 4.7.2. Em Framework anterior, implemente com XOR
  acumulado sobre todos os bytes, sem saída antecipada.
- **Formato versionado.** `pbkdf2-sha256-v1$600000$<salt>$<hash>` permite mudar o custo — ou o
  algoritmo inteiro — sem invalidar o que já está gravado.
- **`precisaRegravar`.** O mesmo mecanismo do `SuccessRehashNeeded`: atualiza o hash no login.

---

## Migrar de um hash legado sem forçar redefinição

O cenário real: a tabela tem 200 mil senhas em MD5 sem salt. Pedir que todos redefinam é caro em
suporte e em confiança, e a taxa de retorno nunca é 100%.

**Estratégia: migração oportunista no login.** O hash antigo continua válido até que o usuário
entre uma vez; nesse momento, o hash é substituído pelo novo.

### Passo 1 — Marcar o algoritmo de cada linha

```sql
-- ATENCAO: altera estrutura. Rode em janela, com backup validado.
-- Coluna com default para nao quebrar a versao anterior da aplicacao
-- (ver devops/deployment/estrategias-de-deployment-e-rollback.md).
ALTER TABLE dbo.Usuario
  ADD AlgoritmoSenha VARCHAR(32) NOT NULL
      CONSTRAINT DF_Usuario_AlgoritmoSenha DEFAULT ('md5-legado');

-- A coluna de hash precisa comportar o formato novo, bem maior que 32 caracteres
ALTER TABLE dbo.Usuario ALTER COLUMN SenhaHash VARCHAR(256) NOT NULL;

-- Auditoria da migracao
ALTER TABLE dbo.Usuario ADD SenhaMigradaEm DATETIME2 NULL;
```

### Passo 2 — Verificar nos dois formatos, gravar no novo

```csharp
public async Task<bool> AutenticarAsync(
    string login, string senhaDigitada, CancellationToken cancellationToken)
{
    var usuario = await _repositorio.ObterPorLoginAsync(login, cancellationToken);

    if (usuario is null)
    {
        // Gasta o mesmo tempo do caminho valido, para nao revelar
        // por temporizacao se o login existe.
        HashDeSenha.Verificar(senhaDigitada, HashDescartavel, out _);
        return false;
    }

    bool autenticou;

    switch (usuario.AlgoritmoSenha)
    {
        case "pbkdf2-sha256-v1":
            autenticou = HashDeSenha.Verificar(
                senhaDigitada, usuario.SenhaHash, out var precisaRegravar);

            if (autenticou && precisaRegravar)
                await RegravarAsync(usuario, senhaDigitada, cancellationToken);
            break;

        case "md5-legado":
            autenticou = VerificarMd5Legado(senhaDigitada, usuario.SenhaHash);

            // Ponto da migracao: a senha em claro so existe aqui, neste instante.
            if (autenticou)
                await RegravarAsync(usuario, senhaDigitada, cancellationToken);
            break;

        default:
            _logger.LogError(
                "Algoritmo de senha desconhecido para o usuario {UsuarioId}: {Algoritmo}",
                usuario.Id, usuario.AlgoritmoSenha);
            return false;
    }

    return autenticou;
}

private async Task RegravarAsync(
    Usuario usuario, string senha, CancellationToken cancellationToken)
{
    usuario.SenhaHash      = HashDeSenha.Gerar(senha);
    usuario.AlgoritmoSenha = "pbkdf2-sha256-v1";
    usuario.SenhaMigradaEm = DateTime.UtcNow;

    await _repositorio.AtualizarAsync(usuario, cancellationToken);
}
```

### Passo 3 — Acompanhar e encerrar

```sql
-- Progresso da migracao
SELECT AlgoritmoSenha,
       COUNT(*)                                          AS quantidade,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS percentual
  FROM dbo.Usuario
 GROUP BY AlgoritmoSenha;

-- Contas que ainda nao migraram e ha quanto tempo nao acessam
SELECT TOP (100) Id, Login, UltimoAcesso
  FROM dbo.Usuario
 WHERE AlgoritmoSenha = 'md5-legado'
 ORDER BY UltimoAcesso;
```

A curva estabiliza: usuários ativos migram nas primeiras semanas; a cauda são contas inativas.
Defina uma data de corte — por exemplo, seis meses. Depois dela, as contas remanescentes têm a
senha invalidada e passam pelo fluxo de redefinição. Isso também é higiene de contas abandonadas.

> **Enquanto a migração durar, o hash fraco continua no banco.** A migração oportunista reduz o
> risco progressivamente, mas não o elimina no dia um. Se houve indício de vazamento da tabela, a
> decisão correta é invalidar tudo e forçar redefinição — conveniência deixa de ser o critério.

---

## Quando NÃO implementar isso

- **Quando existe um provedor de identidade disponível.** Entra ID, Keycloak, Auth0 ou o SSO
  corporativo resolvem autenticação inteira — com MFA, política de senha e bloqueio — e a
  aplicação deixa de guardar senha. Guardar senha é uma responsabilidade a se evitar.
- **Quando a aplicação é ASP.NET Core com Identity.** Use o `PasswordHasher` que já vem pronto.
- **Nunca escreva criptografia própria.** O código acima não inventa nada: usa PBKDF2 da
  biblioteca padrão. Essa é a diferença.

---

## Cuidados que vão além do hash

- **Limitação de taxa por conta e por IP.** Sem isso, hash caro protege o banco vazado, mas o
  ataque por tentativa continua viável — e ainda derruba o servidor por consumo de CPU.
- **Mensagem de erro idêntica** para "usuário inexistente" e "senha incorreta", inclusive no tempo
  de resposta.
- **Nunca logue a senha**, nem em `Debug`, nem no corpo da requisição, nem em exceção. Ver
  [`dotnet/logging/`](../../dotnet/logging/).
- **Token de redefinição** deve ser aleatório criptográfico, de uso único, com validade curta,
  armazenado como hash — ele é equivalente a uma senha.
- **Política de senha:** priorize comprimento mínimo e bloqueio de senhas conhecidamente vazadas.
  Exigência de trocar a cada 90 dias, sem indício de comprometimento, produz senhas piores.

---

## Checklist

- [ ] Nenhuma senha em texto claro ou criptografia reversível.
- [ ] Algoritmo de derivação lenta: Argon2id, scrypt, bcrypt ou PBKDF2 com custo adequado.
- [ ] `Rfc2898DeriveBytes` com `HashAlgorithmName.SHA256` **explícito** (o padrão é SHA-1).
- [ ] Salt aleatório de 16+ bytes, único por senha.
- [ ] Comparação com `CryptographicOperations.FixedTimeEquals`.
- [ ] Hash armazenado em formato versionado, com os parâmetros embutidos.
- [ ] Regravação oportunista quando os parâmetros ficam desatualizados.
- [ ] Coluna de hash dimensionada para o formato novo.
- [ ] Limitação de taxa no endpoint de login.
- [ ] Tempo de resposta igual para login inexistente e senha incorreta.
- [ ] Data de corte definida para encerrar a migração do algoritmo legado.

---

## Referências

- [OWASP — Password Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)
- [Microsoft Learn — `PasswordHasherOptions.IterationCount`](https://learn.microsoft.com/dotnet/api/microsoft.aspnetcore.identity.passwordhasheroptions.iterationcount)
- [Microsoft Learn — `Rfc2898DeriveBytes`](https://learn.microsoft.com/dotnet/api/system.security.cryptography.rfc2898derivebytes)
- [Microsoft Learn — `CryptographicOperations.FixedTimeEquals`](https://learn.microsoft.com/dotnet/api/system.security.cryptography.cryptographicoperations.fixedtimeequals)
- [Microsoft Learn — Password hashing no ASP.NET Core Identity](https://learn.microsoft.com/aspnet/core/security/authentication/identity)

---

**Criado por Fábio Cerqueira**
