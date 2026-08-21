# Timeout e `CancellationToken` em chamadas HTTP

> "A API está retornando timeout" é um dos chamados mais frequentes — e um dos mais mal
> diagnosticados, porque existem **quatro** timeouts diferentes na cadeia e a mensagem de
> erro raramente diz qual deles estourou.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8 · .NET 10 |
| **Impacto** | Configurar mal desperdiça threads e conexões sob carga |

---

## Os quatro timeouts da cadeia

Quando alguém diz "deu timeout", pergunte **onde**:

| # | Timeout | Onde se configura | Padrão típico |
|---|---|---|---|
| 1 | **Cliente HTTP** | `HttpClient.Timeout` | **100 segundos** |
| 2 | **Por tentativa** (com resiliência) | `AttemptTimeout` / `AddTimeout` | 10 segundos |
| 3 | **Servidor** | Configuração do IIS/Kestrel do lado que responde | Varia |
| 4 | **Banco, do outro lado** | `CommandTimeout` na API chamada | 30 segundos |

O caso mais confuso é quando o timeout do cliente (100 s) é **maior** que o do servidor:
a conexão cai do lado de lá e o cliente recebe um erro genérico de conexão, não um timeout.

---

## `HttpClient.Timeout` — o que ele realmente cobre

```csharp
var client = new HttpClient
{
    // Cobre a operacao INTEIRA: conexao, envio, espera e leitura do corpo.
    // O padrao de 100 segundos e alto demais para quase toda API interna.
    Timeout = TimeSpan.FromSeconds(30)
};
```

Pontos que costumam surpreender:

- o relógio cobre também a **leitura do corpo da resposta**. Um download grande em rede
  lenta pode estourar o timeout mesmo com o servidor respondendo rápido;
- o valor é **por instância** de `HttpClient`, não por requisição;
- alterar `Timeout` depois da primeira requisição lança exceção. Configure na criação.

### Timeout diferente para uma chamada específica

Como o `Timeout` é da instância, um valor por requisição se obtém com
`CancellationTokenSource`:

```csharp
using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
cts.CancelAfter(TimeSpan.FromSeconds(5));

try
{
    using var resposta = await _http.GetAsync("v1/consulta-rapida", cts.Token)
                                    .ConfigureAwait(false);
}
catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
{
    // O chamador cancelou de verdade -- propague.
    throw;
}
catch (OperationCanceledException)
{
    // Estourou os 5 segundos deste trecho.
    throw new TimeoutException("A consulta rapida excedeu 5 segundos.");
}
```

`CreateLinkedTokenSource` é o detalhe que importa: sem ele, você perde o cancelamento
vindo do chamador — e a requisição continua rodando depois de o usuário ter ido embora.

---

## Distinguir timeout de cancelamento

Até o .NET 5, `HttpClient` lançava `TaskCanceledException` tanto para timeout quanto para
cancelamento do chamador, sem forma limpa de diferenciar. A partir do **.NET 6**, quando a
causa é o timeout do próprio `HttpClient`, a exceção traz um `TimeoutException` como
`InnerException`:

```csharp
try
{
    using var resposta = await _http.GetAsync(url, cancellationToken)
                                    .ConfigureAwait(false);
}
catch (TaskCanceledException ex) when (ex.InnerException is TimeoutException)
{
    // .NET 6+: foi o HttpClient.Timeout.
    _logger.LogWarning("Timeout do cliente ao chamar {Url}", url);
    throw;
}
catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
{
    // O chamador cancelou -- normalmente nao e erro, e sim fim de request.
    _logger.LogInformation("Chamada a {Url} cancelada pelo chamador", url);
    throw;
}
```

Em .NET Framework, a distinção prática é inspecionar
`cancellationToken.IsCancellationRequested`: se **não** foi solicitado, foi o timeout.

---

## `CancellationToken` — propagar sempre

```csharp
// ❌ O token para aqui. A chamada continua mesmo apos o cliente desistir.
public async Task<Pedido> ObterAsync(int id)
{
    var resposta = await _http.GetAsync($"v1/pedidos/{id}");
    return await resposta.Content.ReadFromJsonAsync<Pedido>();
}

// ✅ Token propagado ate a ponta
public async Task<Pedido?> ObterAsync(int id, CancellationToken cancellationToken)
{
    using var resposta = await _http
        .GetAsync($"v1/pedidos/{id}", cancellationToken)
        .ConfigureAwait(false);

    resposta.EnsureSuccessStatusCode();

    return await resposta.Content
        .ReadFromJsonAsync<Pedido>(cancellationToken: cancellationToken)
        .ConfigureAwait(false);
}
```

Em ASP.NET Core, o `CancellationToken` do controller é acionado quando o cliente fecha a
conexão. Propagá-lo significa que trabalho inútil é abortado — o que, sob carga, libera
threads, conexões e tempo de banco.

```csharp
[HttpGet("{id:int}")]
public async Task<IActionResult> Obter(int id, CancellationToken cancellationToken)
{
    var pedido = await _servico.ObterAsync(id, cancellationToken);
    return pedido is null ? NotFound() : Ok(pedido);
}
```

> Regra prática: todo método `async` que faz I/O deve aceitar um `CancellationToken` e
> passá-lo adiante. Um token que morre no meio da cadeia não cancela nada.

---

## Escolhendo os valores

Não existe número universal. Existe um método:

1. **Meça** a latência real da operação em produção (p95 e p99, não a média).
2. Defina o timeout com **folga sobre o p99**, não sobre a média.
3. Garanta que o timeout do **cliente** seja menor que o do **servidor** — assim você
   recebe um timeout claro em vez de uma conexão cortada.
4. Some: `total = (tentativas × timeout_por_tentativa) + atrasos de backoff`. O teto total
   precisa comportar isso.

| Tipo de chamada | Faixa razoável de partida |
|---|---|
| API interna, consulta simples | 5 a 10 s |
| API externa, parceiro | 15 a 30 s |
| Relatório ou processamento pesado | 60 s ou mais — mas avalie tornar assíncrono |
| Upload ou download de arquivo | Depende do tamanho — considere `ResponseHeadersRead` e progresso |

Operação que precisa de mais de um minuto raramente deveria ser síncrona. Considere
aceitar a requisição com HTTP 202 e devolver um identificador para consulta posterior.

---

## O antipadrão: aumentar o timeout até parar de reclamar

```csharp
// ❌ "Deu timeout, aumenta pra 5 minutos"
client.Timeout = TimeSpan.FromMinutes(5);
```

O que isso causa sob carga:

- cada requisição pendurada segura uma thread e uma conexão por cinco minutos;
- o pool de conexões do servidor esgota;
- a fila de requisições cresce;
- a aplicação inteira para — não só a chamada lenta.

Timeout longo transforma **degradação de um serviço** em **indisponibilidade total**.
Falhar rápido é uma feature.

Se a operação realmente demora, o problema não é o timeout — é o desenho síncrono.

---

## Diagnóstico

| Sintoma | Provavelmente | Verifique |
|---|---|---|
| Timeout sempre por volta de 100 s | `HttpClient.Timeout` no padrão | Configure explicitamente |
| Timeout sempre por volta de 30 s | `CommandTimeout` do banco na API chamada | [`../../acesso-a-dados/ado-net/timeout-de-comando-vs-conexao.md`](../../acesso-a-dados/ado-net/timeout-de-comando-vs-conexao.md) |
| Erro de conexão em vez de timeout | O servidor cortou antes | Alinhe: cliente < servidor |
| Timeout só sob carga | Fila por conexão ou por thread | Veja [`httpclient-uso-correto.md`](httpclient-uso-correto.md) |
| Timeout intermitente em um endpoint só | Query lenta do outro lado | [`../../sql-server/performance/`](../../sql-server/performance/) |

## Referências

- [`HttpClient.Timeout`](https://learn.microsoft.com/pt-br/dotnet/api/system.net.http.httpclient.timeout)
- [Cancelamento em .NET](https://learn.microsoft.com/pt-br/dotnet/standard/threading/cancellation-in-managed-threads)
- [Diretrizes para usar `HttpClient`](https://learn.microsoft.com/pt-br/dotnet/fundamentals/networking/http/httpclient-guidelines)

---

**Criado por Fábio Cerqueira**
