# `HttpClient` — o erro mais caro do .NET, e como não cometê-lo

> `HttpClient` implementa `IDisposable`. A intuição manda envolver em `using`. Fazer isso
> derruba a aplicação em produção sob carga. E a correção ingênua — uma instância estática
> para sempre — introduz um segundo problema, mais sutil.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8 · .NET 10 |
| **Pacotes** | `Microsoft.Extensions.Http` (para `IHttpClientFactory`) |
| **Impacto** | **Alto.** O sintoma aparece sob carga, não em teste |

---

## Problema

A aplicação funciona perfeitamente em desenvolvimento. Em produção, sob carga, começa a
falhar com:

```text
System.Net.Sockets.SocketException: Only one usage of each socket address
(protocol/network address/port) is normally permitted
```

ou, no .NET moderno:

```text
System.Net.Http.HttpRequestException: An error occurred while sending the request.
 ---> System.Net.Sockets.SocketException (10048): Address already in use
```

E no servidor, `netstat -an | find /c "TIME_WAIT"` retorna milhares de conexões.

---

## Por que acontece

```csharp
// ❌ O erro clássico
foreach (var pedido in pedidos)
{
    using (var client = new HttpClient())
    {
        await client.PostAsJsonAsync("https://<HOST-DA-API>/v1/pedidos", pedido);
    }
}
```

O `Dispose` do `HttpClient` fecha o socket TCP subjacente — mas o sistema operacional
**não libera a porta imediatamente**. Ela fica em estado `TIME_WAIT` por um período
(tipicamente na ordem de dezenas de segundos a alguns minutos, conforme a plataforma e a
configuração), para garantir que pacotes atrasados da conexão anterior não sejam
confundidos com uma conexão nova.

Como o intervalo de portas efêmeras disponíveis é finito, uma aplicação que cria e descarta
`HttpClient` em laço esgota as portas do servidor. A partir daí, **nenhuma** conexão de
saída funciona — nem para a API, nem para o banco de dados.

O sintoma aparece minutos ou horas depois do início da carga, o que torna o diagnóstico
especialmente confuso: "funcionava até as 10h".

---

## A correção ingênua, e o segundo problema

```csharp
// ⚠️ Resolve o socket exhaustion e cria outro problema
private static readonly HttpClient Client = new HttpClient();
```

Uma instância estática reutiliza as conexões e elimina o esgotamento de portas. Mas ela
**mantém as conexões abertas indefinidamente** — e conexão aberta não refaz resolução de
DNS.

Consequência prática: se o endereço do serviço mudar — failover, escalonamento, troca de
load balancer, mudança de DNS — a aplicação continua tentando o IP antigo **até ser
reiniciada**. É o clássico "fizemos o failover, tudo voltou, mas o sistema X continua
falhando".

---

## A solução correta, por plataforma

### .NET 8 / .NET 10 — `IHttpClientFactory`

A fábrica gerencia um pool de handlers, reciclando-os periodicamente. Você recebe uma
instância nova de `HttpClient` a cada chamada, barata de criar, apoiada em um handler
compartilhado.

```csharp
// Program.cs
builder.Services.AddHttpClient<ClienteDePedidos>(client =>
{
    client.BaseAddress = new Uri("https://<HOST-DA-API>/");
    client.Timeout = TimeSpan.FromSeconds(30);
    client.DefaultRequestHeaders.Add("User-Agent", "<NOME-DO-SISTEMA>/1.0");
})
.ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
{
    // Fecha e recria conexoes periodicamente: e isto que faz o DNS ser
    // reconsultado sem derrubar o pool.
    PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    PooledConnectionIdleTimeout = TimeSpan.FromMinutes(2),
    MaxConnectionsPerServer = 50
});
```

```csharp
public sealed class ClienteDePedidos
{
    private readonly HttpClient _http;

    // A instancia e injetada; NAO faca Dispose dela.
    public ClienteDePedidos(HttpClient http) => _http = http;

    public async Task<Pedido?> ObterAsync(int id, CancellationToken cancellationToken)
    {
        using var resposta = await _http.GetAsync($"v1/pedidos/{id}", cancellationToken)
                                        .ConfigureAwait(false);

        if (resposta.StatusCode == HttpStatusCode.NotFound)
            return null;

        resposta.EnsureSuccessStatusCode();

        return await resposta.Content
                             .ReadFromJsonAsync<Pedido>(cancellationToken: cancellationToken)
                             .ConfigureAwait(false);
    }
}
```

> **Nunca chame `Dispose` no `HttpClient` recebido da fábrica.** O ciclo de vida é dela.
> Descarte apenas o `HttpResponseMessage`, como no exemplo.

### .NET 8+ sem contêiner de DI

Quando não há injeção de dependência — um utilitário de console, por exemplo — um
`SocketsHttpHandler` estático com `PooledConnectionLifetime` resolve os dois problemas:

```csharp
private static readonly SocketsHttpHandler Handler = new()
{
    PooledConnectionLifetime = TimeSpan.FromMinutes(5)
};

private static readonly HttpClient Client = new(Handler)
{
    BaseAddress = new Uri("https://<HOST-DA-API>/"),
    Timeout = TimeSpan.FromSeconds(30)
};
```

### .NET Framework 4.6.2 – 4.8.1 — o caminho do legado

`SocketsHttpHandler` **não existe** no .NET Framework. A conexão é controlada pelo
`ServicePointManager`. O equivalente ao `PooledConnectionLifetime` é o
`ConnectionLeaseTimeout`:

```csharp
public static class ClienteHttpLegado
{
    private const string BaseUrl = "https://<HOST-DA-API>/";

    private static readonly HttpClient Client;

    static ClienteHttpLegado()
    {
        // 1. TLS 1.2 -- nao e padrao em .NET Framework 4.6.x.
        //    Sem isto, chamadas HTTPS a servicos modernos falham com
        //    "The request was aborted: Could not create SSL/TLS secure channel".
        ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;

        // 2. Limite de conexoes simultaneas por host.
        //    O padrao em aplicacoes ASP.NET e MUITO baixo e vira gargalo.
        ServicePointManager.DefaultConnectionLimit = 50;

        // 3. Forca a reciclagem da conexao -- e assim o DNS volta a ser resolvido.
        var servicePoint = ServicePointManager.FindServicePoint(new Uri(BaseUrl));
        servicePoint.ConnectionLeaseTimeout = (int)TimeSpan.FromMinutes(5).TotalMilliseconds;

        Client = new HttpClient
        {
            BaseAddress = new Uri(BaseUrl),
            Timeout = TimeSpan.FromSeconds(30)
        };
    }

    public static Task<HttpResponseMessage> GetAsync(string caminho) =>
        Client.GetAsync(caminho);
}
```

Em .NET Framework 4.7+ é possível deixar o sistema operacional escolher o protocolo TLS
com `SecurityProtocolType.SystemDefault`, o que é preferível a fixar a versão no código.
Em 4.6.x, fixar `Tls12` costuma ser necessário.

**É possível usar `IHttpClientFactory` no .NET Framework**, via
`Microsoft.Extensions.Http` com `Microsoft.Extensions.DependencyInjection`. Vale a pena em
aplicações que já tenham DI configurada.

---

## Resumo: legado → intermediário → moderno

| | .NET Framework 4.6.2+ | .NET Framework com DI | .NET 8 / .NET 10 |
|---|---|---|---|
| **Instância** | `static readonly HttpClient` | `IHttpClientFactory` | `IHttpClientFactory` |
| **DNS obsoleto** | `ServicePoint.ConnectionLeaseTimeout` | Gerenciado pela fábrica | `PooledConnectionLifetime` |
| **Limite de conexões** | `ServicePointManager.DefaultConnectionLimit` | Idem | `MaxConnectionsPerServer` |
| **TLS** | `ServicePointManager.SecurityProtocol` | Idem | Padrão do sistema |
| **Resiliência** | Polly manual | Polly + `AddPolicyHandler` | `AddStandardResilienceHandler()` |

---

## Outros erros frequentes

### Ler a resposta inteira na memória sem necessidade

```csharp
// ❌ Carrega o corpo inteiro em uma string antes de desserializar
var json = await resposta.Content.ReadAsStringAsync();
var pedido = JsonSerializer.Deserialize<Pedido>(json);

// ✅ Le direto do stream: menos alocação, menos pressão de GC
var pedido = await resposta.Content.ReadFromJsonAsync<Pedido>(cancellationToken);
```

Para respostas grandes, `HttpCompletionOption.ResponseHeadersRead` evita bufferizar o
corpo inteiro antes de começar a processar.

### Não verificar o status

```csharp
// ❌ HTTP 500 passa despercebido e vira erro de desserialização
var pedido = await resposta.Content.ReadFromJsonAsync<Pedido>();

// ✅
if (!resposta.IsSuccessStatusCode)
{
    var corpo = await resposta.Content.ReadAsStringAsync(cancellationToken);
    _logger.LogWarning("API retornou {Status} para {Url}: {Corpo}",
        (int)resposta.StatusCode, resposta.RequestMessage?.RequestUri, corpo);

    throw new HttpRequestException(
        $"API retornou {(int)resposta.StatusCode}");
}
```

`EnsureSuccessStatusCode()` é mais curto, mas descarta o corpo da resposta — e o corpo
costuma trazer a mensagem de erro que explica o problema.

### Cabeçalho de autenticação em `DefaultRequestHeaders` com token por usuário

```csharp
// ❌ Em cliente compartilhado, isto vaza o token de um usuário para outro
Client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);

// ✅ Por requisição
using var requisicao = new HttpRequestMessage(HttpMethod.Get, "v1/pedidos");
requisicao.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
using var resposta = await _http.SendAsync(requisicao, cancellationToken);
```

`DefaultRequestHeaders` só é seguro para valores que valem para **todas** as requisições
daquele cliente — `User-Agent`, `Accept`, uma API key fixa do sistema.

### `.Result` ou `.Wait()`

```csharp
// ❌ Em ASP.NET clássico e WinForms/WPF, isto causa DEADLOCK
var resposta = client.GetAsync(url).Result;
```

Veja [`../async-await/armadilhas-async-await.md`](../async-await/armadilhas-async-await.md).

---

## Como confirmar o diagnóstico em produção

```powershell
# Quantidade de conexoes em TIME_WAIT (Windows)
netstat -an | Select-String "TIME_WAIT" | Measure-Object | Select-Object Count

# Conexoes por processo
Get-NetTCPConnection -State TimeWait | Group-Object -Property OwningProcess |
    Sort-Object Count -Descending | Select-Object -First 10

# Faixa de portas efemeras configurada
netsh int ipv4 show dynamicport tcp
```

Milhares de `TIME_WAIT` originados do processo da sua aplicação confirmam o padrão de
criação e descarte de `HttpClient`.

> Ampliar a faixa de portas efêmeras ou reduzir o tempo de `TIME_WAIT` no sistema
> operacional são **paliativos**. Compram tempo; não corrigem o código.

---

## Checklist

- [ ] Nenhum `new HttpClient()` dentro de método chamado com frequência.
- [ ] Nenhum `using` envolvendo `HttpClient` (o `HttpResponseMessage`, sim).
- [ ] `IHttpClientFactory` no .NET moderno, ou estático com reciclagem no legado.
- [ ] `PooledConnectionLifetime` (moderno) ou `ConnectionLeaseTimeout` (legado) configurado.
- [ ] `Timeout` definido conscientemente — o padrão é 100 segundos.
- [ ] `CancellationToken` propagado em todas as chamadas.
- [ ] Status HTTP verificado, com o corpo registrado em log no erro.
- [ ] Token por usuário **não** vai em `DefaultRequestHeaders`.
- [ ] Retry e circuit breaker configurados — veja [`resiliencia-retry-circuit-breaker.md`](resiliencia-retry-circuit-breaker.md).
- [ ] Em .NET Framework: TLS 1.2 e `DefaultConnectionLimit` configurados.

## Referências

- [`IHttpClientFactory` no .NET](https://learn.microsoft.com/pt-br/dotnet/core/extensions/httpclient-factory)
- [Diretrizes para usar `HttpClient`](https://learn.microsoft.com/pt-br/dotnet/fundamentals/networking/http/httpclient-guidelines)
- [`SocketsHttpHandler`](https://learn.microsoft.com/pt-br/dotnet/api/system.net.http.socketshttphandler)
- [`ServicePointManager`](https://learn.microsoft.com/pt-br/dotnet/api/system.net.servicepointmanager)

---

**Criado por Fábio Cerqueira**
