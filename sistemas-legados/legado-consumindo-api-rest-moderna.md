# Sistema legado precisa consumir uma API REST moderna

> Um WebForms de 2011, .NET Framework 4.6.2, precisa chamar uma API que exige TLS 1.2,
> JSON e Bearer token. Este documento é o passo a passo do que quebra e como resolver — sem
> migrar a plataforma.

| | |
|---|---|
| **Contexto** | .NET Framework 4.6.2+ (WebForms, MVC 5, WinForms, serviço Windows) |
| **Pacotes** | `Newtonsoft.Json`, opcionalmente `Microsoft.Extensions.Http` e `Polly` |
| **Impacto** | Erros aqui derrubam o legado, não a API |

---

## Os cinco obstáculos, na ordem em que aparecem

| # | Obstáculo | Sintoma |
|---|---|---|
| 1 | TLS 1.2 não negociado | `Could not create SSL/TLS secure channel` |
| 2 | `HttpClient` mal usado | Funciona em teste, esgota portas em produção |
| 3 | `async/await` em código síncrono | Deadlock: a página nunca responde |
| 4 | JSON | `Newtonsoft.Json` — `System.Text.Json` não é nativo aqui |
| 5 | Token e resiliência | Token expira; falha transitória derruba a operação |

---

## Obstáculo 1 — TLS 1.2

O erro mais comum, e o que dá menos pistas:

```text
The request was aborted: Could not create SSL/TLS secure channel.
```

O .NET Framework 4.6.x negocia por padrão protocolos que os servidores modernos já
desabilitaram.

```csharp
// Uma unica vez, no inicio da aplicacao:
//   WebForms/MVC .... Application_Start, no Global.asax
//   Servico Windows .. OnStart
//   Console .......... Main

// |= preserva o que ja estava configurado, em vez de sobrescrever
ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
```

Em .NET Framework **4.7 ou superior**, prefira deixar a decisão com o sistema operacional —
assim, quando o TLS 1.3 se tornar o padrão, a aplicação acompanha sem novo deploy:

```xml
<!-- app.config / web.config -->
<runtime>
  <AppContextSwitchOverrides
      value="Switch.System.Net.DontEnableSystemDefaultTlsVersions=false" />
</runtime>
```

Se mesmo assim falhar, verifique no servidor: TLS 1.2 habilitado no registro do Windows, e
a cadeia de certificação da API instalada.

---

## Obstáculo 2 — `HttpClient` único e com reciclagem

```csharp
public static class ClienteDaApi
{
    private const string BaseUrl = "https://<HOST-DA-API>/";

    private static readonly HttpClient Client;

    static ClienteDaApi()
    {
        // 1. TLS
        ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;

        // 2. Conexoes simultaneas: o padrao em ASP.NET e baixo e vira gargalo
        ServicePointManager.DefaultConnectionLimit = 50;

        // 3. Forca a reciclagem da conexao a cada 5 minutos.
        //    Sem isto, uma instancia estatica NUNCA reconsulta o DNS -- e a
        //    aplicacao sobrevive a um failover apontando para o IP antigo.
        var servicePoint = ServicePointManager.FindServicePoint(new Uri(BaseUrl));
        servicePoint.ConnectionLeaseTimeout = (int)TimeSpan.FromMinutes(5).TotalMilliseconds;

        Client = new HttpClient
        {
            BaseAddress = new Uri(BaseUrl),
            Timeout = TimeSpan.FromSeconds(30)
        };

        Client.DefaultRequestHeaders.Accept.Add(
            new MediaTypeWithQualityHeaderValue("application/json"));

        Client.DefaultRequestHeaders.Add("User-Agent", "<NOME-DO-SISTEMA>/1.0");
    }

    internal static HttpClient Instancia => Client;
}
```

> **Nunca** `using (var client = new HttpClient())` dentro de um método chamado com
> frequência. Detalhes e diagnóstico em
> [`../dotnet/httpclient/httpclient-uso-correto.md`](../dotnet/httpclient/httpclient-uso-correto.md).

---

## Obstáculo 3 — chamar código assíncrono de código síncrono

Este é o que trava a aplicação.

```csharp
// ❌ DEADLOCK em WebForms e MVC 5. A pagina nunca responde.
protected void Page_Load(object sender, EventArgs e)
{
    var pedido = ClienteDaApi.ObterPedidoAsync(42).Result;
}
```

### Solução A — tornar a página assíncrona (preferível)

WebForms suporta operações assíncronas desde o .NET Framework 4.5:

```aspx
<%@ Page Async="true" ... %>
```

```csharp
protected void Page_Load(object sender, EventArgs e)
{
    RegisterAsyncTask(new PageAsyncTask(async () =>
    {
        var pedido = await ClienteDaApi.ObterPedidoAsync(42).ConfigureAwait(false);
        PreencherTela(pedido);
    }));
}
```

Em MVC 5, basta a action retornar `async Task<ActionResult>`.

### Solução B — `ConfigureAwait(false)` em toda a cadeia

Se a página não pode virar assíncrona, garanta que **todos** os `await` da cadeia chamada
usem `ConfigureAwait(false)`. Um único esquecido recria o deadlock.

### Solução C — isolar em thread do pool (último recurso)

```csharp
// Funciona, mas desperdica uma thread por chamada.
var pedido = Task.Run(() => ClienteDaApi.ObterPedidoAsync(42))
                 .GetAwaiter()
                 .GetResult();
```

Mais detalhes em
[`../dotnet/async-await/armadilhas-async-await.md`](../dotnet/async-await/armadilhas-async-await.md).

---

## Obstáculo 4 — JSON

`System.Text.Json` não faz parte do .NET Framework. O caminho é `Newtonsoft.Json`, que é
maduro, funciona bem e continua suportado.

```csharp
using Newtonsoft.Json;

private static readonly JsonSerializerSettings Configuracao = new JsonSerializerSettings
{
    NullValueHandling = NullValueHandling.Ignore,
    DateTimeZoneHandling = DateTimeZoneHandling.Utc,

    // APIs modernas costumam usar camelCase
    ContractResolver = new Newtonsoft.Json.Serialization.CamelCasePropertyNamesContractResolver(),

    // Falhe alto: campo desconhecido pode significar mudanca de contrato
    MissingMemberHandling = MissingMemberHandling.Ignore
};

public static async Task<Pedido> ObterPedidoAsync(int id)
{
    using (var resposta = await ClienteDaApi.Instancia
               .GetAsync("v1/pedidos/" + id)
               .ConfigureAwait(false))
    {
        var corpo = await resposta.Content.ReadAsStringAsync().ConfigureAwait(false);

        if (!resposta.IsSuccessStatusCode)
        {
            // O corpo do erro quase sempre explica o problema. Nao descarte.
            throw new HttpRequestException(
                string.Format("API retornou {0}: {1}", (int)resposta.StatusCode, corpo));
        }

        return JsonConvert.DeserializeObject<Pedido>(corpo, Configuracao);
    }
}
```

### Cuidados de serialização

| Cuidado | Detalhe |
|---|---|
| **Fuso horário** | `DateTimeZoneHandling` evita que a data mude de valor entre os sistemas. Prefira `DateTimeOffset` ou UTC explícito |
| **Cultura** | Um `decimal` serializado com vírgula quebra a API. `JsonConvert` usa cultura invariante por padrão — não troque isso |
| **Nomes** | `camelCase` na API, `PascalCase` no C#. Resolva no `ContractResolver`, não renomeando as propriedades |
| **Encoding** | Garanta UTF-8 na leitura e na escrita; caracteres acentuados são o teste |
| **`decimal`, não `double`** | Valor monetário em `double` acumula erro de arredondamento |

---

## Obstáculo 5 — Token e resiliência

```csharp
public static class ProvedorDeToken
{
    private static readonly object Trava = new object();
    private static string _token;
    private static DateTime _expiraEmUtc = DateTime.MinValue;

    public static string Obter()
    {
        // Caminho rapido, sem travar
        if (_token != null && DateTime.UtcNow < _expiraEmUtc)
            return _token;

        lock (Trava)
        {
            // Outra thread pode ter renovado enquanto esperavamos
            if (_token != null && DateTime.UtcNow < _expiraEmUtc)
                return _token;

            var conteudo = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                { "grant_type",    "client_credentials" },
                { "client_id",     ConfigurationManager.AppSettings["OAuth:ClientId"] },
                { "client_secret", ConfigurationManager.AppSettings["OAuth:ClientSecret"] }
            });

            using (var resposta = ClienteDaApi.Instancia
                       .PostAsync("oauth/token", conteudo)
                       .GetAwaiter().GetResult())
            {
                resposta.EnsureSuccessStatusCode();

                var corpo = resposta.Content.ReadAsStringAsync()
                                    .GetAwaiter().GetResult();

                var payload = JsonConvert.DeserializeObject<RespostaDeToken>(corpo);

                _token = payload.AccessToken;

                // Margem de 2 minutos: evita a corrida com o relogio do servidor
                _expiraEmUtc = DateTime.UtcNow
                                       .AddSeconds(payload.ExpiresIn)
                                       .AddMinutes(-2);

                return _token;
            }
        }
    }

    private class RespostaDeToken
    {
        [JsonProperty("access_token")] public string AccessToken { get; set; }
        [JsonProperty("expires_in")]   public int    ExpiresIn   { get; set; }
    }
}
```

O `GetAwaiter().GetResult()` aqui é aceitável porque está dentro de um `lock`, em código
de infraestrutura chamado raramente — e não em caminho de requisição. Ainda assim, se a
aplicação for assíncrona ponta a ponta, prefira a versão `async` do
[`../api-integracao/autenticacao/autenticacao-em-apis.md`](../api-integracao/autenticacao/autenticacao-em-apis.md).

**O token vai por requisição, nunca em `DefaultRequestHeaders`:**

```csharp
using (var requisicao = new HttpRequestMessage(HttpMethod.Get, "v1/pedidos/" + id))
{
    requisicao.Headers.Authorization =
        new AuthenticationHeaderValue("Bearer", ProvedorDeToken.Obter());

    using (var resposta = await ClienteDaApi.Instancia
               .SendAsync(requisicao).ConfigureAwait(false))
    {
        // ...
    }
}
```

### Retry com Polly v7

Polly v8 exige plataformas mais novas; em .NET Framework, use a linha v7:

```csharp
private static readonly Random Aleatorio = new Random();

private static readonly Policy<HttpResponseMessage> Politica =
    Policy<HttpResponseMessage>
        .Handle<HttpRequestException>()
        .OrResult(r => (int)r.StatusCode >= 500
                    || r.StatusCode == HttpStatusCode.RequestTimeout
                    || (int)r.StatusCode == 429)
        .WaitAndRetryAsync(
            retryCount: 3,
            sleepDurationProvider: tentativa =>
            {
                int jitter;
                lock (Aleatorio) { jitter = Aleatorio.Next(0, 500); }

                return TimeSpan.FromSeconds(Math.Pow(2, tentativa))
                     + TimeSpan.FromMilliseconds(jitter);
            });
```

> **`Random` não é thread-safe.** O `lock` acima é necessário; sem ele, chamadas
> concorrentes podem receber a mesma sequência — anulando o jitter justamente quando ele
> mais importa.

E, antes de habilitar retry em `POST`, garanta idempotência:
[`../api-integracao/resiliencia/retry-seguro-e-idempotencia.md`](../api-integracao/resiliencia/retry-seguro-e-idempotencia.md).

---

## Onde guardar a credencial

```xml
<!-- ❌ Nunca versione isto -->
<appSettings>
  <add key="OAuth:ClientSecret" value="segredo-real-aqui" />
</appSettings>
```

```xml
<!-- ✅ Arquivo externo, fora do controle de versao -->
<appSettings configSource="appSettings.secrets.config" />
```

Adicione `appSettings.secrets.config` ao `.gitignore` e distribua o arquivo pelo processo
de deploy. Em .NET Framework, também é possível criptografar seções do `web.config` com
`aspnet_regiis -pe`.

---

## Checklist

- [ ] TLS 1.2 habilitado no início da aplicação.
- [ ] `HttpClient` único, estático, com `ConnectionLeaseTimeout`.
- [ ] `DefaultConnectionLimit` ajustado.
- [ ] Nenhum `.Result`/`.Wait()` em caminho de requisição — ou `ConfigureAwait(false)` em
      toda a cadeia.
- [ ] `Page Async="true"` onde for WebForms.
- [ ] Token cacheado com margem e proteção contra renovação concorrente.
- [ ] Token enviado **por requisição**.
- [ ] Retry com jitter, e `Random` protegido.
- [ ] `decimal` para valor monetário; datas em UTC ou `DateTimeOffset`.
- [ ] Corpo do erro registrado em log quando a API falha.
- [ ] Credenciais fora do repositório.

## Referências

- [Melhores práticas de TLS com .NET Framework](https://learn.microsoft.com/pt-br/dotnet/framework/network-programming/tls)
- [Diretrizes para usar `HttpClient`](https://learn.microsoft.com/pt-br/dotnet/fundamentals/networking/http/httpclient-guidelines)
- [Newtonsoft.Json — documentação](https://www.newtonsoft.com/json/help/html/Introduction.htm)
- [Páginas assíncronas em WebForms](https://learn.microsoft.com/pt-br/aspnet/web-forms/overview/performance-and-caching/using-asynchronous-methods-in-aspnet-45)

---

**Criado por Fábio Cerqueira**
