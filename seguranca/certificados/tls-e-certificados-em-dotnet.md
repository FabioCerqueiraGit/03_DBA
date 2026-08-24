# TLS e certificados em .NET — diagnosticar sem desligar a validação

> "The remote certificate is invalid", "Could not create SSL/TLS secure channel", integração que
> parou sozinha — e por que a correção que aparece primeiro no buscador é a errada.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.5+ e .NET Core/5+. As diferenças entre plataformas são o ponto central deste documento. |
| **Impacto** | Diagnóstico: nenhum. As correções mexem em configuração de servidor. |

---

## Problema

Erro de TLS tem uma característica cruel: a mensagem quase nunca diz a causa.
`Could not create SSL/TLS secure channel` pode significar protocolo incompatível, certificado
expirado, cadeia incompleta, algoritmo não suportado ou nome que não confere — e a exceção é a
mesma em todos os casos.

A busca por essa mensagem devolve, quase sempre, a mesma "solução":

```csharp
// NUNCA em codigo que vai para producao.
ServicePointManager.ServerCertificateValidationCallback = (s, c, ch, e) => true;
```

Isso não conserta nada. Desliga a única verificação que garante que você está falando com quem
acha que está falando — TLS vira criptografia sem autenticação, vulnerável a interceptação. E,
porque "funcionou", ninguém volta para investigar.

---

## Roteiro de diagnóstico

### Passo 1 — Testar fora da aplicação, no mesmo servidor

```powershell
# Mostra o certificado que o servidor apresenta e se a cadeia valida
$conexao = [Net.HttpWebRequest]::Create('https://<HOST-DA-API>')
$conexao.GetResponse() | Out-Null
$conexao.ServicePoint.Certificate | Format-List Subject, Issuer, NotBefore, NotAfter
```

```bash
# Linux ou Windows com OpenSSL: mostra a cadeia inteira que o servidor envia
openssl s_client -connect <HOST-DA-API>:443 -servername <HOST-DA-API> -showcerts </dev/null
```

O `-servername` importa: sem ele, servidores com múltiplos sites (SNI) devolvem o certificado
errado, e você diagnostica o problema de outra pessoa.

Se o teste fora da aplicação **também** falha, o problema é de ambiente (cadeia, data, protocolo),
não de código.

### Passo 2 — Ler o motivo exato, sem desligar nada

Em vez de retornar `true`, use o callback para **registrar** o que está errado:

```csharp
// Uso TEMPORARIO de diagnostico. Remover apos identificar a causa.
var handler = new HttpClientHandler
{
    ServerCertificateCustomValidationCallback = (mensagem, certificado, cadeia, erros) =>
    {
        if (erros == SslPolicyErrors.None)
            return true;

        logger.LogWarning(
            "Falha de validacao TLS. Erros={Erros} Subject={Subject} Emissor={Emissor} " +
            "ValidoDe={De} ValidoAte={Ate}",
            erros,
            certificado?.Subject,
            certificado?.Issuer,
            certificado?.NotBefore,
            certificado?.NotAfter);

        foreach (var elemento in cadeia?.ChainStatus ?? Array.Empty<X509ChainStatus>())
            logger.LogWarning("Cadeia: {Status} - {Info}",
                elemento.Status, elemento.StatusInformation);

        // Continua REJEITANDO. O callback so registra.
        return false;
    }
};
```

`SslPolicyErrors` tem três valores que apontam direto para a causa:

| Valor | Significado | Causa mais comum |
|---|---|---|
| `RemoteCertificateNotAvailable` | O servidor não enviou certificado | Endpoint não é HTTPS, ou proxy no meio |
| `RemoteCertificateNameMismatch` | O nome não bate | Acesso por IP ou por alias que não está no SAN do certificado |
| `RemoteCertificateChainErrors` | A cadeia não valida | Expirado, CA não confiável, ou **intermediária faltando** |

---

## Causa 1 — Protocolo: TLS 1.2 no .NET Framework

Esta é a causa mais comum em sistema legado, e a que mais confunde: **o mesmo código funcionava e
parou**, sem ninguém ter mexido nele. O que mudou foi o servidor do outro lado, que desabilitou
TLS 1.0/1.1.

| Versão do .NET Framework | Comportamento padrão |
|---|---|
| Até 4.6.x | `ServicePointManager.SecurityProtocol` começa em SSL 3.0 + TLS 1.0 |
| 4.6 e 4.6.1 | TLS 1.2 disponível, mas não padrão sem configuração |
| **4.7+** | Usa o padrão do sistema operacional (`SystemDefault`) — o correto |
| .NET Core / .NET 5+ | Sempre delega ao sistema operacional |

### A correção certa: recompilar para 4.7+

```xml
<!-- app.config ou web.config -->
<runtime>
  <AppContextSwitchOverrides value="Switch.System.Net.DontEnableSystemDefaultTlsVersions=false" />
</runtime>
```

Com `targetFramework` 4.7 ou superior, a aplicação passa a negociar o que o sistema operacional
suporta — e sobe junto quando o SO for atualizado, sem novo deployment.

### A correção possível quando não dá para recompilar

```csharp
// Executar UMA vez, na inicializacao da aplicacao (Global.asax / Main).
// Nunca dentro de um metodo chamado por requisicao.
ServicePointManager.SecurityProtocol =
    SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11;
```

> Isto é uma amarração: quando o mundo migrar para TLS 1.3, este código vai impedir a negociação.
> Trate como paliativo com prazo, e registre a dívida.

`ServicePointManager` é **global ao processo**. Definir isso em uma biblioteca afeta toda a
aplicação — o que é tanto o motivo de funcionar quanto o motivo de causar surpresa.

---

## Causa 2 — Cadeia incompleta (a mais subestimada)

Sintoma clássico: **funciona no navegador, falha na aplicação.**

Navegadores mantêm cache de certificados intermediários e sabem buscar o que falta pelo campo
*Authority Information Access*. O .NET, dependendo da plataforma e do sistema, não faz isso da
mesma forma. Se o servidor não envia a intermediária, a cadeia não fecha.

```bash
# Quantos certificados o servidor realmente envia?
openssl s_client -connect <HOST>:443 -servername <HOST> -showcerts </dev/null 2>/dev/null \
  | grep -c "BEGIN CERTIFICATE"
```

Um único certificado, em cadeia que deveria ter folha + intermediária, é o diagnóstico.

**A correção é no servidor que apresenta o certificado**, não no cliente: reinstalar o certificado
com a cadeia completa. Se o servidor for de terceiros, esse é o conteúdo do chamado a abrir — com
a saída do `openssl` anexada, o que costuma encurtar a discussão consideravelmente.

Paliativo aceitável enquanto o terceiro não corrige: instalar a intermediária no store
*Intermediate Certification Authorities* da máquina cliente. Isso é diferente de desligar a
validação — a cadeia continua sendo verificada.

---

## Causa 3 — Nome que não confere

`RemoteCertificateNameMismatch` significa que o host usado na URL não está no *Subject Alternative
Name* do certificado. Acontece tipicamente quando se acessa por IP, por nome curto de máquina, ou
por um alias de DNS criado depois da emissão.

> Desde há muitas versões, o campo `CN` sozinho não basta: a validação considera o SAN. Certificado
> antigo emitido apenas com CN falha em clientes modernos.

Correção: use a URL que corresponde ao certificado, ou reemita o certificado incluindo o nome
usado. Não existe atalho legítimo aqui.

---

## Causa 4 — Certificado expirado

Óbvio depois de descoberto, invisível antes. Vale monitorar em vez de descobrir por incidente:

```powershell
# Certificados da maquina local que vencem nos proximos 30 dias
Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.NotAfter -lt (Get-Date).AddDays(30) } |
    Select-Object Subject, NotAfter, Thumbprint |
    Sort-Object NotAfter
```

O mesmo vale para o certificado que **você** apresenta a terceiros — inclusive o de cliente usado
em integrações autenticadas por certificado.

---

## Certificado de cliente (mutual TLS)

Quando a API exige certificado do cliente:

```csharp
// .NET Core / .NET 5+
var certificado = new X509Certificate2(
    caminhoDoPfx,
    senhaDoPfx,
    X509KeyStorageFlags.MachineKeySet | X509KeyStorageFlags.EphemeralKeySet);

var handler = new HttpClientHandler();
handler.ClientCertificates.Add(certificado);
handler.ClientCertificateOptions = ClientCertificateOption.Manual;
```

Melhor ainda — carregar do store, sem arquivo `.pfx` nem senha em lugar nenhum:

```csharp
using var store = new X509Store(StoreName.My, StoreLocation.LocalMachine);
store.Open(OpenFlags.ReadOnly);

var encontrados = store.Certificates.Find(
    X509FindType.FindByThumbprint, "<THUMBPRINT>", validOnly: false);

if (encontrados.Count == 0)
    throw new InvalidOperationException("Certificado de cliente nao encontrado no store.");

handler.ClientCertificates.Add(encontrados[0]);
```

### A armadilha do IIS: permissão na chave privada

O erro mais comum em mutual TLS sob IIS não é de certificado — é de **permissão**. A identidade do
Application Pool precisa de acesso de leitura à chave privada. Sem isso, o certificado é
encontrado, mas a assinatura falha, com mensagem que não menciona permissão.

Concessão pela interface: `certlm.msc` → certificado → *All Tasks* → *Manage Private Keys* →
adicionar `IIS AppPool\<NOME-DO-POOL>` com permissão de leitura.

Ver também [`iis/troubleshooting/`](../../iis/troubleshooting/).

---

## Quando desligar a validação é aceitável

Quase nunca. As duas exceções reais:

1. **Ambiente de desenvolvimento local**, contra servidor com certificado autoassinado, com o
   código isolado por `#if DEBUG` ou por verificação de ambiente — de modo que seja
   **impossível** que chegue a produção:

```csharp
if (ambiente.IsDevelopment())
{
    handler.ServerCertificateCustomValidationCallback =
        HttpClientHandler.DangerousAcceptAnyServerCertificateValidator;
}
```

   O nome do membro começa com `Dangerous` por escolha deliberada da Microsoft. Use-o em vez de um
   lambda `=> true`: assim o risco fica legível para quem revisar o código depois.

2. **Certificate pinning**, que é o oposto de afrouxar — validação customizada que exige um
   thumbprint específico:

```csharp
handler.ServerCertificateCustomValidationCallback = (_, certificado, _, erros) =>
    erros == SslPolicyErrors.None &&
    string.Equals(certificado?.Thumbprint, thumbprintEsperado, StringComparison.OrdinalIgnoreCase);
```

   Pinning quebra silenciosamente quando o parceiro renova o certificado. Só adote com processo de
   atualização combinado e alerta de vencimento.

---

## TLS entre a aplicação e o SQL Server

O `Microsoft.Data.SqlClient` mudou o padrão na versão 4.0: **`Encrypt` passou a ser `True` por
padrão**. Aplicações que migraram do `System.Data.SqlClient` passam a falhar com erro de
certificado se o SQL Server usa certificado autoassinado.

```text
Server=<SERVIDOR>;Database=<BANCO>;Integrated Security=true;Encrypt=True;TrustServerCertificate=False
```

`TrustServerCertificate=True` é o equivalente, aqui, a desligar a validação: a conexão é
criptografada, mas não autenticada. A correção correta é instalar no SQL Server um certificado
emitido por uma CA em que os clientes confiam.

Ver [`acesso-a-dados/ado-net/`](../../acesso-a-dados/ado-net/).

---

## Checklist

- [ ] Causa identificada por `SslPolicyErrors`, não por tentativa e erro.
- [ ] Nenhum `=> true` em callback de validação em código de produção.
- [ ] .NET Framework com `targetFramework` 4.7+ ou `SecurityProtocol` definido uma única vez na
      inicialização — com prazo para remover o paliativo.
- [ ] Cadeia do servidor verificada com `openssl s_client -showcerts`.
- [ ] Certificados com vencimento monitorado, não descoberto por incidente.
- [ ] Chave privada com permissão para a identidade do Application Pool (mutual TLS em IIS).
- [ ] `.pfx` e senha fora do repositório — ver [`seguranca/secrets/`](../secrets/).
- [ ] `TrustServerCertificate=True` tratado como pendência, não como configuração definitiva.

---

## Referências

- [Microsoft Learn — Transport Layer Security (TLS) best practices with the .NET Framework](https://learn.microsoft.com/dotnet/framework/network-programming/tls)
- [Microsoft Learn — `SslPolicyErrors`](https://learn.microsoft.com/dotnet/api/system.net.security.sslpolicyerrors)
- [Microsoft Learn — `HttpClientHandler.ServerCertificateCustomValidationCallback`](https://learn.microsoft.com/dotnet/api/system.net.http.httpclienthandler.servercertificatecustomvalidationcallback)
- [Microsoft Learn — `X509Store`](https://learn.microsoft.com/dotnet/api/system.security.cryptography.x509certificates.x509store)
- [Microsoft Learn — Connection string `Encrypt` no Microsoft.Data.SqlClient](https://learn.microsoft.com/sql/connect/ado-net/connection-string-syntax)

---

**Criado por Fábio Cerqueira**
