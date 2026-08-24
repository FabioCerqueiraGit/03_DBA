# Gerenciamento de segredos em aplicações .NET

> Onde a connection string, o token e a chave privada devem morar — do sistema em .NET Framework
> com `web.config` até a aplicação moderna sem senha nenhuma.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.5+ e .NET Core/5+. Cada seção declara o alvo. |
| **Impacto** | Mudança de origem de configuração afeta a subida da aplicação. Teste em homologação. |
| **Regra do repositório** | Nenhum valor real aqui. Todo exemplo usa `<PLACEHOLDER>`. |

---

## Problema

Toda aplicação precisa de pelo menos um segredo: a senha do banco. A pergunta não é "como
esconder" — é **quem precisa conhecer o valor, e por quanto tempo**.

Os padrões ruins têm todos a mesma assinatura: o segredo em texto claro, em um arquivo que muita
gente lê, sem rotação e sem trilha de quem acessou.

| Onde o segredo costuma estar | Por que é ruim |
|---|---|
| `appsettings.json` commitado | Todo mundo com acesso de leitura ao repositório tem a senha, para sempre (o histórico não esquece) |
| `web.config` versionado | Idem, e ainda aparece em backup de código e em pacote de publicação |
| Constante no código | Idem, e ainda está no binário compilado — visível em qualquer descompilador |
| Planilha compartilhada | Sem trilha, sem rotação, e circula por e-mail |
| Variável de ambiente da máquina | Aceitável; melhor que os anteriores, mas legível por qualquer processo do mesmo usuário |
| Cofre (Key Vault / Secrets Manager) | Com rotação, trilha de acesso e escopo |
| **Sem segredo nenhum** (identidade gerenciada / autenticação integrada) | O melhor: não existe valor para vazar |

---

## A hierarquia de decisão

Em ordem de preferência, do melhor para o aceitável:

1. **Elimine o segredo.** Autenticação integrada do Windows contra SQL Server, ou identidade
   gerenciada no Azure. Sem senha, não há rotação, vazamento nem planilha.
2. **Cofre gerenciado.** Azure Key Vault, AWS Secrets Manager, HashiCorp Vault. A aplicação busca
   o valor em tempo de execução, autenticando-se por identidade.
3. **Variável de ambiente provisionada pela esteira**, com o valor nascendo no cofre da esteira e
   nunca em arquivo versionado.
4. **Arquivo local fora do repositório**, provisionado pelo deployment e protegido por permissão de
   sistema de arquivos.

Qualquer coisa abaixo disso é dívida a ser paga.

---

## Desenvolvimento local — User Secrets (.NET Core / .NET 5+)

User Secrets guarda o valor **no perfil do usuário**, fora da pasta do projeto. Não há como
commitá-lo por acidente, porque ele simplesmente não está lá.

```bash
cd src/Api
dotnet user-secrets init
dotnet user-secrets set "ConnectionStrings:Principal" "Server=<SERVIDOR>;Database=<BANCO>;Integrated Security=true;Encrypt=True;TrustServerCertificate=False"
dotnet user-secrets set "Integracao:ApiKey" "<CHAVE>"

# Conferir o que esta guardado
dotnet user-secrets list
```

O `dotnet user-secrets init` adiciona um `<UserSecretsId>` ao `.csproj`. Esse GUID **pode** ser
versionado — ele é só um identificador de pasta, não um segredo.

No código, nada muda: `AddUserSecrets` é registrado automaticamente pelo host quando o ambiente é
`Development`.

```csharp
var builder = WebApplication.CreateBuilder(args);

// A cadeia de configuracao ja inclui, nesta ordem de precedencia crescente:
//   appsettings.json
//   appsettings.{Environment}.json
//   User Secrets (apenas em Development)
//   Variaveis de ambiente
//   Argumentos de linha de comando

var conexao = builder.Configuration.GetConnectionString("Principal")
    ?? throw new InvalidOperationException("ConnectionStrings:Principal nao configurada.");
```

> **User Secrets não é criptografado.** É um JSON em texto claro no perfil do usuário. Ele resolve
> o problema de "vazou no Git", não o de "a máquina foi comprometida". Nunca coloque credencial de
> produção nele.

**Falhe alto e cedo.** O `?? throw` acima não é detalhe: sem ele, a aplicação sobe com
`connectionString = null` e falha bem mais tarde, com uma mensagem que não aponta para a causa.

---

## Produção — variáveis de ambiente

O provedor de variáveis de ambiente usa `__` (dois sublinhados) como separador de nível, porque
`:` não é válido em nome de variável em todas as plataformas:

```bash
# Linux / contêiner
export ConnectionStrings__Principal="Server=<SERVIDOR>;Database=<BANCO>;..."
export Integracao__ApiKey="<CHAVE>"
```

```powershell
# Windows, no escopo da maquina
[Environment]::SetEnvironmentVariable('ConnectionStrings__Principal', '<VALOR>', 'Machine')
```

No IIS, o caminho mais controlado é declarar no `web.config` gerado pelo publish, dentro de
`aspNetCore/environmentVariables` — lembrando que esse `web.config` **não deve ser versionado com
o valor real**, e sim gerado pela esteira.

---

## Produção — Azure Key Vault

Pacotes: `Azure.Identity` e `Azure.Extensions.AspNetCore.Configuration.Secrets`.

```csharp
var builder = WebApplication.CreateBuilder(args);

if (!builder.Environment.IsDevelopment())
{
    builder.Configuration.AddAzureKeyVault(
        new Uri($"https://<NOME-DO-COFRE>.vault.azure.net/"),
        new DefaultAzureCredential());
}
```

`DefaultAzureCredential` tenta uma cadeia de mecanismos em ordem: identidade gerenciada, variáveis
de ambiente, Azure CLI, Visual Studio. Isso permite que o mesmo código funcione na máquina do
desenvolvedor (via `az login`) e no servidor (via identidade gerenciada), **sem nenhum segredo em
lugar nenhum**.

O segredo `Integracao--ApiKey` no cofre vira `Integracao:ApiKey` na configuração — o provedor
traduz `--` em `:`.

### Cuidados com Key Vault

- **Os valores são lidos na inicialização.** Rotacionar o segredo no cofre não afeta uma
  aplicação já em execução, a menos que você configure recarga periódica (`AzureKeyVaultConfigurationOptions.ReloadInterval`)
  ou reinicie. Recarga periódica custa chamadas ao cofre; escolha o intervalo conscientemente.
- **O cofre é uma dependência de inicialização.** Cofre indisponível = aplicação não sobe. Isso é
  geralmente correto (melhor do que subir sem credencial), mas precisa estar no desenho de
  disponibilidade.
- **Permissão mínima:** a identidade da aplicação precisa apenas de *get* e *list* de secrets.
  Não conceda *set* nem *delete* — a aplicação lê segredos, não os administra.

---

## O melhor caminho: nenhum segredo

### SQL Server em rede com Active Directory

```text
Server=<SERVIDOR>;Database=<BANCO>;Integrated Security=true;Encrypt=True;TrustServerCertificate=False
```

A aplicação autentica com a identidade do Application Pool (IIS) ou da conta de serviço. Não há
senha na connection string. A permissão é concedida a uma conta de domínio ou a um grupo:

```sql
-- No SQL Server
CREATE LOGIN [<DOMINIO>\<CONTA-DE-SERVICO>] FROM WINDOWS;
CREATE USER  [<DOMINIO>\<CONTA-DE-SERVICO>] FOR LOGIN [<DOMINIO>\<CONTA-DE-SERVICO>];
ALTER ROLE app_execucao ADD MEMBER [<DOMINIO>\<CONTA-DE-SERVICO>];
```

### Azure SQL com identidade gerenciada

Com `Microsoft.Data.SqlClient` 3.0+:

```text
Server=<SERVIDOR>.database.windows.net;Database=<BANCO>;Authentication=Active Directory Default;Encrypt=True
```

Valores de `Authentication` disponíveis e a versão mínima do driver:

| Valor | Uso | Versão mínima |
|---|---|---|
| `Active Directory Integrated` | Windows integrado com Entra ID | 2.0.0 |
| `Active Directory Interactive` | Login interativo com MFA | 2.0.0 |
| `Active Directory Service Principal` | Client ID + secret | 2.0.0 |
| `Active Directory Managed Identity` | Identidade gerenciada atribuída ao recurso | 2.1.0 |
| `Active Directory Default` | Cadeia sem senha: identidade gerenciada, Visual Studio, Azure CLI | 3.0.0 |
| `Active Directory Workload Identity` | Identidade federada (Kubernetes / Workload Identity) | 5.2.0 |

> **Atenção de versão:** a partir do `Microsoft.Data.SqlClient` **7.0**, as dependências de Azure e
> Entra ID saíram do pacote principal. Para usar qualquer modo `Active Directory *`, é preciso
> instalar também o pacote `Microsoft.Data.SqlClient.Extensions.Azure`. Migração para 7.0 sem esse
> pacote quebra a autenticação em tempo de execução, não em compilação.

---

## Legado — .NET Framework e `web.config`

### Opção 1: `configSource` (a mais simples)

A seção vai para um arquivo separado, que fica no `.gitignore` e é provisionado pelo deployment:

```xml
<!-- web.config, versionado -->
<configuration>
  <connectionStrings configSource="connections.config" />
</configuration>
```

```xml
<!-- connections.config, NAO versionado -->
<connectionStrings>
  <add name="Principal"
       connectionString="Server=&lt;SERVIDOR&gt;;Database=&lt;BANCO&gt;;Integrated Security=true"
       providerName="System.Data.SqlClient" />
</connectionStrings>
```

Vantagem: simples, funciona em qualquer versão do Framework, e o `web.config` versionado deixa de
conter segredo. Limitação: o valor continua em texto claro no servidor — a proteção é a permissão
de sistema de arquivos (o Application Pool lê; mais ninguém).

### Opção 2: criptografia de seção com `aspnet_regiis`

O .NET Framework criptografa seções do `web.config` usando DPAPI ou um container RSA:

```powershell
# Executar no servidor, como administrador.
# -pe = protect (encrypt) | -app = caminho da aplicacao no IIS
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\aspnet_regiis.exe" `
    -pe "connectionStrings" -app "/MinhaAplicacao" -prov "RsaProtectedConfigurationProvider"

# Para reverter:
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\aspnet_regiis.exe" `
    -pd "connectionStrings" -app "/MinhaAplicacao"
```

A aplicação continua lendo normalmente com `ConfigurationManager.ConnectionStrings` — a
descriptografia é transparente.

**O que isso protege e o que não protege:**

| Protege contra | Não protege contra |
|---|---|
| Leitura casual do arquivo por quem tem acesso ao disco | Quem tem acesso administrativo à máquina (pode simplesmente descriptografar) |
| Cópia do `web.config` para outra máquina | Comprometimento do processo da aplicação |
| Backup do site levando a senha em claro | Falta de rotação |

**Duas armadilhas operacionais:**

1. Com `RsaProtectedConfigurationProvider`, a chave fica no container RSA da máquina. Um
   `web.config` criptografado copiado para outro servidor **não descriptografa** — é preciso
   exportar e importar o container (`aspnet_regiis -px` / `-pi`). Em farm de servidores isso vira
   procedimento obrigatório de provisionamento.
2. Com `DataProtectionConfigurationProvider` (DPAPI), a amarração à máquina é ainda mais forte.

### Opção 3: a melhor para legado — eliminar a senha

Trocar SQL Authentication por autenticação integrada, com o Application Pool rodando sob uma conta
de serviço de domínio, resolve o problema em vez de escondê-lo. Custa uma conversa com a equipe de
infraestrutura e um ajuste de permissão — e elimina a categoria inteira.

---

## Quando NÃO usar cada opção

| Opção | Não use quando |
|---|---|
| User Secrets | Em produção, sob qualquer justificativa. É ferramenta de desenvolvimento. |
| Variável de ambiente | O valor precisa de rotação automática ou trilha de acesso auditada. |
| Key Vault | A aplicação precisa subir com o cofre indisponível, ou o custo por chamada importa e não há cache. |
| `aspnet_regiis` | Você espera que isso substitua rotação e menor privilégio. Não substitui. |
| Identidade gerenciada | Não há Entra ID / Active Directory no caminho (por exemplo, SQL Server em rede sem domínio). |

---

## Higiene que vale para qualquer opção

- **Segredo diferente por ambiente.** Desenvolvimento, homologação e produção nunca compartilham
  credencial. Se compartilham, o ambiente menos protegido define a segurança de todos.
- **Rotação com data.** Um segredo sem data de rotação é permanente na prática.
- **Nunca logue o valor.** Isso inclui logar o objeto de configuração inteiro em nível `Debug`.
  Ver [`dotnet/logging/`](../../dotnet/logging/).
- **Nunca devolva o valor por API**, nem em endpoint de diagnóstico interno.
- **Cuidado com a mensagem de exceção.** `SqlException` costuma incluir o servidor e o banco. Em
  ambiente de desenvolvimento isso ajuda; em produção vai para o log, nunca para a tela.
- **`.gitignore` cobrindo os formatos**, e **push protection ativa** — ver
  [`devops/git/remover-segredo-vazado-do-historico.md`](../../devops/git/remover-segredo-vazado-do-historico.md).

---

## Checklist

- [ ] Nenhum segredo em arquivo versionado — verificado com `git log -p --all -S "Password="`.
- [ ] Desenvolvimento usa User Secrets ou arquivo local ignorado, nunca `appsettings.json`.
- [ ] Produção usa cofre, variável de ambiente provisionada ou — melhor — nenhuma senha.
- [ ] A aplicação **falha na inicialização** se um segredo obrigatório estiver ausente.
- [ ] Credencial distinta por ambiente.
- [ ] Data de rotação definida e registrada.
- [ ] Permissão no cofre limitada a leitura.
- [ ] Nenhum segredo em log, em mensagem de erro ao usuário ou em endpoint de diagnóstico.
- [ ] Se `Microsoft.Data.SqlClient` 7.0+ com autenticação Entra ID: pacote
      `Microsoft.Data.SqlClient.Extensions.Azure` instalado.

---

## Referências

- [Microsoft Learn — Safe storage of app secrets in development in ASP.NET Core](https://learn.microsoft.com/aspnet/core/security/app-secrets)
- [Microsoft Learn — Azure Key Vault configuration provider in ASP.NET Core](https://learn.microsoft.com/aspnet/core/security/key-vault-configuration)
- [Microsoft Learn — Microsoft Entra authentication com Microsoft.Data.SqlClient](https://learn.microsoft.com/sql/connect/ado-net/sql/azure-active-directory-authentication)
- [Microsoft Learn — Configuration in ASP.NET Core](https://learn.microsoft.com/aspnet/core/fundamentals/configuration/)
- [Microsoft Learn — `aspnet_regiis.exe` e Protected Configuration](https://learn.microsoft.com/previous-versions/aspnet/dtkwfdky(v=vs.100))

---

**Criado por Fábio Cerqueira**
