# Consumir SOAP e WCF — do legado ao .NET moderno

> SOAP não morreu. Prefeituras, bancos, seguradoras, órgãos públicos e ERPs continuam
> expondo WebServices SOAP, e vai continuar sendo assim por muitos anos. Este documento
> cobre os três cenários reais.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ (WCF completo) · .NET 8/10 (cliente WCF via pacotes) |
| **Pacotes (.NET moderno)** | `System.ServiceModel.Http`, `System.ServiceModel.Primitives` |
| **Impacto** | Erros de canal WCF vazam conexão silenciosamente |

---

## Os três cenários

| Cenário | Plataforma | Caminho |
|---|---|---|
| Sistema .NET Framework consome SOAP | 4.6.2+ | *Add Service Reference* ou `svcutil` — suporte completo |
| Sistema .NET 8/10 consome SOAP | .NET moderno | `dotnet-svcutil` + pacotes `System.ServiceModel.*` — **cliente**, não servidor |
| Sistema .NET moderno **expõe** SOAP | .NET moderno | **CoreWCF** — o WCF de servidor não foi portado pela Microsoft |

> O ponto que mais gera frustração: **o WCF de servidor não existe no .NET moderno.** O que
> a Microsoft portou foi o lado **cliente**. Para hospedar serviços SOAP fora do .NET
> Framework, o caminho é o projeto de código aberto **CoreWCF**.

---

## Gerar o cliente

### .NET Framework

No Visual Studio: **Add Service Reference** apontando para o WSDL. Ou pela linha de
comando:

```bash
svcutil.exe https://<HOST>/servico.asmx?wsdl /out:ClienteDoServico.cs /config:app.config
```

### .NET 8 / .NET 10

```bash
dotnet tool install --global dotnet-svcutil

dotnet-svcutil https://<HOST>/servico.asmx?wsdl --outputFile ClienteDoServico.cs
```

Os pacotes necessários:

```bash
dotnet add package System.ServiceModel.Http
dotnet add package System.ServiceModel.Primitives
# Para seguranca WS-*:
dotnet add package System.ServiceModel.Security
```

> Quando o WSDL não está acessível pela rede (típico em ambiente fechado), salve o `.wsdl`
> e os `.xsd` em disco e aponte o `svcutil` para o arquivo local.

---

## Configurar o cliente por código

Configurar por código é preferível a depender de `app.config`/`web.config`: fica versão
controlada junto ao uso, e funciona igual nas duas plataformas.

```csharp
using System.ServiceModel;

var binding = new BasicHttpBinding(BasicHttpSecurityMode.Transport)
{
    // Os padroes de tamanho sao pequenos (64 KB) e derrubam retornos grandes
    MaxReceivedMessageSize = 20 * 1024 * 1024,   // 20 MB
    MaxBufferSize          = 20 * 1024 * 1024,

    SendTimeout    = TimeSpan.FromSeconds(60),
    ReceiveTimeout = TimeSpan.FromSeconds(60),
    OpenTimeout    = TimeSpan.FromSeconds(15),
    CloseTimeout   = TimeSpan.FromSeconds(15)
};

binding.ReaderQuotas.MaxStringContentLength = 20 * 1024 * 1024;
binding.ReaderQuotas.MaxArrayLength         = 20 * 1024 * 1024;
binding.ReaderQuotas.MaxDepth               = 64;

var endpoint = new EndpointAddress("https://<HOST>/servico.asmx");

var cliente = new ServicoClient(binding, endpoint);

// Autenticacao basica sobre TLS
cliente.ClientCredentials.UserName.UserName = "<USUARIO>";
cliente.ClientCredentials.UserName.Password = "<SENHA>";
```

### Bindings mais comuns

| Binding | Quando |
|---|---|
| `BasicHttpBinding` | SOAP 1.1, `.asmx` clássico. O mais comum em legado |
| `WSHttpBinding` | SOAP 1.2 com WS-Security e WS-ReliableMessaging |
| `CustomBinding` | Quando o serviço exige uma combinação que os prontos não cobrem |
| `NetTcpBinding` | Só entre sistemas .NET, em rede interna. Mais rápido |

---

## Fechar o canal corretamente — o erro que vaza conexão

```csharp
// ❌ O using NAO e seguro com clientes WCF.
// Se o canal estiver em estado Faulted, o Dispose chama Close(), que LANCA --
// mascarando a excecao original e deixando o canal aberto.
using (var cliente = new ServicoClient(binding, endpoint))
{
    return cliente.Consultar(parametro);
}
```

```csharp
// ✅ Padrao correto: Close no caminho feliz, Abort no caminho de erro
public async Task<Resultado> ConsultarAsync(string parametro)
{
    var cliente = new ServicoClient(_binding, _endpoint);

    try
    {
        var resultado = await cliente.ConsultarAsync(parametro).ConfigureAwait(false);

        await Task.Factory
            .FromAsync(cliente.BeginClose, cliente.EndClose, null)
            .ConfigureAwait(false);

        return resultado;
    }
    catch
    {
        // Abort NUNCA lanca. E o que garante a liberacao do canal.
        cliente.Abort();
        throw;
    }
}
```

Uma forma mais simples, quando a API síncrona basta:

```csharp
var cliente = new ServicoClient(_binding, _endpoint);
try
{
    var resultado = cliente.Consultar(parametro);
    cliente.Close();
    return resultado;
}
catch
{
    cliente.Abort();
    throw;
}
```

Este é um dos pontos mais mal resolvidos em código WCF legado, e a causa de vazamento de
canais que só aparece sob carga.

---

## TLS — o erro número um em legado

```text
The request was aborted: Could not create SSL/TLS secure channel.
```

O serviço do parceiro desabilitou TLS 1.0 e 1.1 (como todos fizeram), e a aplicação em
.NET Framework 4.6.x ainda negocia com o protocolo antigo.

```csharp
// No inicio da aplicacao (Application_Start, Main, construtor estatico)
ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
```

Em .NET Framework 4.7 ou superior, prefira deixar o sistema operacional decidir:

```xml
<!-- runtimeconfig / app.config -->
<runtime>
  <AppContextSwitchOverrides value="Switch.System.Net.DontEnableSystemDefaultTlsVersions=false" />
</runtime>
```

No .NET moderno, o padrão já é o do sistema operacional e não costuma exigir nada.

---

## Certificado de cliente (mTLS)

Comúm em integrações com órgãos públicos e instituições financeiras:

```csharp
var binding = new BasicHttpBinding(BasicHttpSecurityMode.Transport);
binding.Security.Transport.ClientCredentialType = HttpClientCredentialType.Certificate;

var cliente = new ServicoClient(binding, endpoint);

// ✅ Carregar do repositorio de certificados do Windows, por thumbprint.
//    NUNCA embuta um .pfx no projeto nem versione a senha dele.
cliente.ClientCredentials.ClientCertificate.SetCertificate(
    StoreLocation.LocalMachine,
    StoreName.My,
    X509FindType.FindByThumbprint,
    "<THUMBPRINT-DO-CERTIFICADO>");
```

Quando o processo roda como serviço do Windows ou sob um Application Pool do IIS, a conta
precisa de **permissão de leitura na chave privada** do certificado. Este é o motivo mais
comum de "funciona na minha máquina e falha no servidor".

---

## Diagnosticar: ver o XML que trafega

### Rastreamento de mensagens (.NET Framework)

```xml
<system.diagnostics>
  <sources>
    <source name="System.ServiceModel.MessageLogging">
      <listeners>
        <add name="messages"
             type="System.Diagnostics.XmlWriterTraceListener"
             initializeData="<CAMINHO>\mensagens.svclog" />
      </listeners>
    </source>
  </sources>
</system.diagnostics>

<system.serviceModel>
  <diagnostics>
    <messageLogging logEntireMessage="true"
                    logMalformedMessages="true"
                    logMessagesAtServiceLevel="true"
                    logMessagesAtTransportLevel="true" />
  </diagnostics>
</system.serviceModel>
```

O arquivo `.svclog` abre no **Service Trace Viewer** (`SvcTraceViewer.exe`), que vem com o
Windows SDK.

> **`logEntireMessage="true"` grava o corpo completo das mensagens** — incluindo
> credenciais e dados pessoais. Use apenas em diagnóstico, com prazo, e apague os arquivos
> depois. Nunca deixe ligado em produção.

### Inspector de mensagens (funciona nas duas plataformas)

Um `IClientMessageInspector` permite registrar as mensagens sem depender de configuração:

```csharp
public sealed class InspectorDeMensagens : IClientMessageInspector
{
    private readonly ILogger _logger;

    public InspectorDeMensagens(ILogger logger) => _logger = logger;

    public object? BeforeSendRequest(ref Message request, IClientChannel channel)
    {
        // Cuidado: pode conter dado sensivel. Filtre antes de registrar.
        _logger.LogDebug("SOAP Request: {Mensagem}", request.ToString());
        return null;
    }

    public void AfterReceiveReply(ref Message reply, object correlationState)
    {
        _logger.LogDebug("SOAP Reply: {Mensagem}", reply.ToString());
    }
}
```

---

## Erros e o que significam

| Erro | Causa provável | Correção |
|---|---|---|
| `Could not create SSL/TLS secure channel` | TLS antigo, ou certificado do servidor não confiável | Habilitar TLS 1.2+; conferir a cadeia de certificação |
| `The maximum message size quota for incoming messages (65536) has been exceeded` | Resposta maior que o padrão | Aumentar `MaxReceivedMessageSize` e `ReaderQuotas` |
| `The content type text/html of the response message does not match the content type of the binding` | O serviço devolveu uma página de erro HTML, não SOAP | Ler o corpo como texto: costuma ser HTTP 500 ou página de login |
| `MessageSecurityException: The HTTP request is unauthorized` | Credencial ausente ou binding de segurança diferente do esperado | Conferir `BasicHttpSecurityMode` e o tipo de credencial |
| `The communication object ... cannot be used for communication because it is in the Faulted state` | Canal quebrado e reutilizado | `Abort()` e criar novo canal; nunca reutilizar canal em falha |
| `The socket connection was aborted` | Timeout, ou o servidor fechou | Ajustar `SendTimeout`/`ReceiveTimeout`; verificar o lado do servidor |
| `An error occurred while receiving the HTTP response` | Frequentemente proxy, firewall ou binding incompatível | Comparar o WSDL com o binding configurado |

---

## Quando o WSDL não coopera

Acontece: WSDL inválido, com referências quebradas, ou que o `svcutil` não consegue
processar. Duas saídas:

1. **Corrigir o WSDL localmente** — salvar, ajustar as referências e gerar a partir do
   arquivo.
2. **Montar o envelope SOAP à mão** e enviar com `HttpClient`. Menos elegânte, mas
   funciona e é totalmente controlável:

```csharp
var envelope = $"""
    <?xml version="1.0" encoding="utf-8"?>
    <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
      <soap:Body>
        <Consultar xmlns="http://<NAMESPACE-DO-SERVICO>/">
          <parametro>{System.Security.SecurityElement.Escape(parametro)}</parametro>
        </Consultar>
      </soap:Body>
    </soap:Envelope>
    """;

using var conteudo = new StringContent(envelope, Encoding.UTF8, "text/xml");
conteudo.Headers.Add("SOAPAction", "http://<NAMESPACE-DO-SERVICO>/Consultar");

using var resposta = await _http.PostAsync("servico.asmx", conteudo, cancellationToken);
var xml = await resposta.Content.ReadAsStringAsync(cancellationToken);
```

**Escape sempre** os valores interpolados no XML. Sem isso, um `&` ou `<` no dado quebra a
mensagem — e, em cenário adverso, permite injeção de XML.

O cabeçalho `SOAPAction` é obrigatório em SOAP 1.1 e sua ausência causa erros genéricos e
confusos do lado do servidor.

---

## Checklist

- [ ] Cliente fechado com `Close()` no sucesso e `Abort()` no erro — nunca `using`.
- [ ] Timeouts e limites de tamanho definidos explicitamente.
- [ ] TLS 1.2+ garantido em .NET Framework.
- [ ] Certificado carregado do repositestório do Windows por thumbprint, nunca de `.pfx` versionado.
- [ ] Conta do Application Pool com permissão na chave privada.
- [ ] Rastreamento de mensagens desligado em produção.
- [ ] Valores escapados ao montar XML manualmente.
- [ ] Retry e timeout tratados — ver [`../resiliencia/retry-seguro-e-idempotencia.md`](../resiliencia/retry-seguro-e-idempotencia.md).

## Referências

- [WCF — documentação](https://learn.microsoft.com/pt-br/dotnet/framework/wcf/)
- [`dotnet-svcutil`](https://learn.microsoft.com/pt-br/dotnet/core/additional-tools/dotnet-svcutil-guide)
- [CoreWCF](https://github.com/CoreWCF/CoreWCF)
- [Fechar clientes WCF corretamente](https://learn.microsoft.com/pt-br/dotnet/framework/wcf/samples/use-close-abort-release-wcf-client-resources)

---

**Criado por Fábio Cerqueira**
