# Resiliência em chamadas HTTP — retry, backoff, circuit breaker e timeout

> Toda integração falha. A diferença entre um sistema que se recupera e um que cai em
> cascata está em como ele trata a falha — e em **não repetir o que não pode ser repetido**.

| | |
|---|---|
| **Compatibilidade** | .NET 8 / .NET 10 (Polly v8) · .NET Framework 4.6.2+ (Polly v7) |
| **Pacotes** | `Microsoft.Extensions.Http.Resilience`, `Polly.Core` |
| **Impacto** | **Alto se mal configurado.** Retry cego duplica operação e amplifica incidente |

---

## A regra que vem antes de qualquer código

> **Só repita o que é seguro repetir.**

| Situação | Classificação | Repetir? |
|---|---|---|
| HTTP 500, 502, 503, 504 | Transitória | **Sim** |
| HTTP 429 (*Too Many Requests*) | Transitória | Sim — **respeitando `Retry-After`** |
| HTTP 408 (*Request Timeout*) | Transitória | Sim |
| Falha de rede antes de enviar | Transitória | Sim |
| **Timeout após enviar** | **Indeterminada** | **Só se a operação for idempotente** |
| HTTP 400, 401, 403, 404, 422 | Permanente | **Não.** Repetir não muda o resultado |

O caso do meio é o perigoso. Timeout não significa que nada aconteceu: significa que você
**não sabe** se aconteceu. Repetir um `POST /pagamentos` que talvez tenha sido processado
gera cobrança dupla.

A saída é **idempotência**, não coragem. Veja
[`../../api-integracao/resiliencia/retry-seguro-e-idempotencia.md`](../../api-integracao/resiliencia/retry-seguro-e-idempotencia.md).

---

## .NET 8 / .NET 10 — o caminho curto

O pacote `Microsoft.Extensions.Http.Resilience` traz um conjunto padrão pronto:

```bash
dotnet add package Microsoft.Extensions.Http.Resilience
```

```csharp
builder.Services
    .AddHttpClient<ClienteDePedidos>(client =>
    {
        client.BaseAddress = new Uri("https://<HOST-DA-API>/");
    })
    .AddStandardResilienceHandler();
```

Uma linha, e a chamada passa a ter cinco estratégias encadeadas, nesta ordem:

| # | Estratégia | Padrão |
|---|---|---|
| 1 | Rate limiter | Limita requisições concorrentes |
| 2 | Total timeout | 30 segundos para a operação inteira, incluindo retries |
| 3 | Retry | 3 tentativas, backoff exponencial **com jitter** |
| 4 | Circuit breaker | Abre a partir de uma proporção de falhas na janela de amostragem |
| 5 | Attempt timeout | 10 segundos por tentativa individual |

A ordem importa: o *total timeout* envolve tudo, então a operação nunca ultrapassa o teto
mesmo com retries; o *attempt timeout* impede que uma única tentativa consuma o orçamento
inteiro.

### Ajustando os padrões

```csharp
.AddStandardResilienceHandler(options =>
{
    options.TotalRequestTimeout.Timeout   = TimeSpan.FromSeconds(60);
    options.AttemptTimeout.Timeout        = TimeSpan.FromSeconds(15);

    options.Retry.MaxRetryAttempts        = 4;
    options.Retry.Delay                   = TimeSpan.FromSeconds(1);
    options.Retry.BackoffType             = DelayBackoffType.Exponential;
    options.Retry.UseJitter               = true;

    options.CircuitBreaker.FailureRatio    = 0.3;
    options.CircuitBreaker.SamplingDuration = TimeSpan.FromSeconds(30);
    options.CircuitBreaker.MinimumThroughput = 10;
    options.CircuitBreaker.BreakDuration    = TimeSpan.FromSeconds(15);
});
```

> Há uma relação de coerência entre esses valores: o *sampling duration* do circuit breaker
> precisa ser compatível com o *attempt timeout*, e o *total timeout* precisa comportar
> todas as tentativas com seus atrasos. A biblioteca valida parte disso e falha na
> configuração — o que é melhor do que falhar em produção.

---

## Polly v8 — controle fino

Quando o conjunto padrão não serve, monte a pipeline:

```csharp
using Polly;
using Polly.Retry;
using Polly.CircuitBreaker;

var pipeline = new ResiliencePipelineBuilder<HttpResponseMessage>()

    // 1. RETRY -- so para o que faz sentido repetir
    .AddRetry(new RetryStrategyOptions<HttpResponseMessage>
    {
        ShouldHandle = new PredicateBuilder<HttpResponseMessage>()
            .Handle<HttpRequestException>()
            .Handle<TimeoutRejectedException>()
            .HandleResult(r => r.StatusCode >= HttpStatusCode.InternalServerError
                            || r.StatusCode == HttpStatusCode.RequestTimeout
                            || r.StatusCode == HttpStatusCode.TooManyRequests),

        MaxRetryAttempts = 3,
        Delay            = TimeSpan.FromSeconds(1),
        BackoffType      = DelayBackoffType.Exponential,

        // Sem jitter, todos os clientes que falharam voltam JUNTOS e derrubam
        // o servico de novo. Este e o "thundering herd".
        UseJitter = true,

        OnRetry = args =>
        {
            logger.LogWarning(
                "Tentativa {Tentativa} apos {Atraso}ms. Motivo: {Motivo}",
                args.AttemptNumber + 1,
                args.RetryDelay.TotalMilliseconds,
                args.Outcome.Exception?.Message
                    ?? args.Outcome.Result?.StatusCode.ToString());

            return default;
        }
    })

    // 2. CIRCUIT BREAKER -- para de bater em servico que ja caiu
    .AddCircuitBreaker(new CircuitBreakerStrategyOptions<HttpResponseMessage>
    {
        ShouldHandle = new PredicateBuilder<HttpResponseMessage>()
            .Handle<HttpRequestException>()
            .HandleResult(r => r.StatusCode >= HttpStatusCode.InternalServerError),

        FailureRatio      = 0.5,                       // 50% de falha
        SamplingDuration  = TimeSpan.FromSeconds(30),  // na janela de 30s
        MinimumThroughput = 10,                        // com ao menos 10 chamadas
        BreakDuration     = TimeSpan.FromSeconds(30),  // abre por 30s

        OnOpened = args =>
        {
            logger.LogError("Circuito ABERTO por {Duracao}s",
                args.BreakDuration.TotalSeconds);
            return default;
        },
        OnClosed = args =>
        {
            logger.LogInformation("Circuito FECHADO - servico recuperado");
            return default;
        }
    })

    // 3. TIMEOUT por tentativa
    .AddTimeout(TimeSpan.FromSeconds(10))

    .Build();
```

```csharp
// Uso
var resposta = await pipeline.ExecuteAsync(
    async ct => await http.GetAsync("v1/pedidos", ct),
    cancellationToken);
```

### `MinimumThroughput` é o parâmetro que evita falso positivo

Sem ele, duas falhas em duas chamadas dariam 100% de taxa de erro e abririam o circuito —
em um serviço que recebe três requisições por hora, isso é ruído, não incidente.
`MinimumThroughput` exige um volume mínimo antes de a proporção significar alguma coisa.

---

## .NET Framework 4.6.2+ — Polly v7

Polly v8 exige plataformas mais recentes. Em .NET Framework, a linha v7 continua válida e
tem API diferente — baseada em `Policy`, não em `ResiliencePipelineBuilder`:

```csharp
using Polly;
using Polly.Extensions.Http;

// Retry com backoff exponencial e jitter
var random = new Random();

var politicaDeRetry = HttpPolicyExtensions
    .HandleTransientHttpError()                 // 5xx e 408
    .OrResult(r => r.StatusCode == (HttpStatusCode)429)
    .WaitAndRetryAsync(
        retryCount: 3,
        sleepDurationProvider: tentativa =>
            TimeSpan.FromSeconds(Math.Pow(2, tentativa))
            + TimeSpan.FromMilliseconds(random.Next(0, 500)),
        onRetry: (resultado, espera, tentativa, contexto) =>
        {
            Trace.TraceWarning(
                "Tentativa {0} apos {1}ms", tentativa, espera.TotalMilliseconds);
        });

// Circuit breaker
var politicaDeCircuito = HttpPolicyExtensions
    .HandleTransientHttpError()
    .CircuitBreakerAsync(
        handledEventsAllowedBeforeBreaking: 5,
        durationOfBreak: TimeSpan.FromSeconds(30));

// Composicao: o retry envolve o circuito
var politica = Policy.WrapAsync(politicaDeRetry, politicaDeCircuito);

var resposta = await politica.ExecuteAsync(() => Client.GetAsync("v1/pedidos"));
```

A instância de `Random` acima precisa ser compartilhada com cuidado em cenário
multithread; em .NET Framework, encapsule-a com sincronização ou use
`RandomNumberGenerator`.

---

## Erros que transformam resiliência em problema

| Erro | Consequência |
|---|---|
| **Retry sem jitter** | Todos os clientes que falharam voltam no mesmo instante e derrubam o serviço de novo |
| **Retry em `POST` não idempotente** | Operação duplicada. Pedido em dobro, cobrança em dobro |
| **Retry em erro 4xx** | Desperdício puro. HTTP 401 não vira 200 na terceira tentativa |
| **Retry sem teto de tempo total** | Uma requisição pode consumir minutos, segurando thread e conexão |
| **Retry aninhado** | Retry na camada de infraestrutura + retry no serviço + retry no cliente = 27 chamadas para uma operação |
| **Circuit breaker sem `MinimumThroughput`** | Abre por ruído estatístico em serviço de baixo volume |
| **Circuit breaker sem log** | O sistema para de chamar o parceiro e ninguém sabe por quê |
| **Ignorar `Retry-After` no 429** | Você insiste contra o *rate limit* e prolonga o bloqueio |

### Respeitando `Retry-After`

```csharp
DelayGenerator = args =>
{
    // Se o servidor disse quanto esperar, obedeca.
    var retryAfter = args.Outcome.Result?.Headers.RetryAfter;

    if (retryAfter?.Delta is { } delta)
        return ValueTask.FromResult<TimeSpan?>(delta);

    if (retryAfter?.Date is { } data)
        return ValueTask.FromResult<TimeSpan?>(data - DateTimeOffset.UtcNow);

    return ValueTask.FromResult<TimeSpan?>(null);  // usa o backoff padrao
}
```

---

## Observabilidade — sem isso você fica cego

O circuit breaker é particularmente traiçoeiro: quando ele abre, a aplicação **para de
chamar** o parceiro e falha rapidamente. Do lado de fora, parece que "o sistema está
rejeitando tudo" — sem nenhum erro de rede visível.

Registre sempre:

- cada tentativa de retry, com número e motivo;
- abertura e fechamento do circuito, em nível de erro/aviso;
- o **correlation ID** propagado em toda a cadeia, para amarrar as tentativas.

```csharp
// Correlation ID atravessando a chamada
requisicao.Headers.TryAddWithoutValidation("X-Correlation-Id", correlationId);
```

Alerte quando o circuito abrir. É informação de operação, não detalhe técnico.

---

## Checklist

- [ ] Retry apenas para falhas transitórias classificadas.
- [ ] Backoff exponencial **com jitter**.
- [ ] `Retry-After` respeitado em HTTP 429.
- [ ] Operações não idempotentes protegidas por chave de idempotência antes de habilitar retry.
- [ ] Timeout por tentativa **e** teto de tempo total.
- [ ] Circuit breaker com `MinimumThroughput` compatível com o volume real.
- [ ] Abertura e fechamento do circuito registrados e alertados.
- [ ] Sem retry aninhado entre camadas.
- [ ] Correlation ID propagado.

## Referências

- [Resiliência HTTP no .NET](https://learn.microsoft.com/pt-br/dotnet/core/resilience/http-resilience)
- [Introdução ao desenvolvimento resiliente](https://learn.microsoft.com/pt-br/dotnet/core/resilience/)
- [Polly — documentação](https://www.pollydocs.org/)
- [Polly — estratégia de retry](https://www.pollydocs.org/strategies/retry.html)
- [Polly — circuit breaker](https://www.pollydocs.org/strategies/circuit-breaker.html)

---

**Criado por Fábio Cerqueira**
