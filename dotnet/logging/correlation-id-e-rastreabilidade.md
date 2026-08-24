# Correlation ID — rastrear uma requisição de ponta a ponta

> O cliente liga dizendo que o pedido 48213 falhou às 14h32. Você tem o log da aplicação, o
> log da API do parceiro, o log do gateway e as DMVs do SQL Server — quatro fontes que não
> conversam. O correlation ID é o que as costura.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8 · .NET 10 · SQL Server 2016+ para o último passo |
| **Impacto** | Baixo. Um cabeçalho e um escopo de log |
| **Retorno** | Alto. É a diferença entre investigar e adivinhar |

---

## O problema

Sem correlation ID, investigar um incidente é assim:

```text
14:32:04  [API Pedidos]  Erro ao emitir nota
14:32:04  [API Pedidos]  Erro ao emitir nota
14:32:05  [API Pedidos]  Erro ao emitir nota
```

Três erros no mesmo segundo. São três pedidos diferentes ou três tentativas do mesmo? Qual
deles corresponde à chamada que travou no banco? Não dá para saber.

Com correlation ID:

```text
14:32:04  [API Pedidos]   corr=7f3a1b  Pedido 48213 recebido
14:32:04  [API Fiscal]    corr=7f3a1b  Chamada recebida
14:32:05  [API Fiscal]    corr=7f3a1b  Timeout no SEFAZ apos 8000ms
14:32:05  [API Pedidos]   corr=7f3a1b  Falha ao emitir nota do pedido 48213
```

Uma consulta por `corr=7f3a1b` reconstrói a história inteira, atravessando sistemas.

---

## Passo 1 — Gerar ou aceitar na borda

A regra: **se o chamador mandou um, respeite; se não mandou, gere.** Assim a cadeia se
mantém mesmo quando a requisição vem de fora.

```csharp
public sealed class MiddlewareDeCorrelationId
{
    public const string Cabecalho = "X-Correlation-Id";

    private readonly RequestDelegate _proximo;
    private readonly ILogger<MiddlewareDeCorrelationId> _logger;

    public MiddlewareDeCorrelationId(
        RequestDelegate proximo, ILogger<MiddlewareDeCorrelationId> logger)
    {
        _proximo = proximo;
        _logger  = logger;
    }

    public async Task InvokeAsync(HttpContext contexto)
    {
        var correlationId = ObterOuGerar(contexto);

        // Devolve no cabecalho de resposta: o cliente passa a poder informar
        // o identificador ao abrir um chamado.
        contexto.Response.OnStarting(() =>
        {
            contexto.Response.Headers[Cabecalho] = correlationId;
            return Task.CompletedTask;
        });

        // Disponibiliza para o resto do pipeline
        contexto.Items[Cabecalho] = correlationId;

        // Todo log emitido daqui para frente carrega o campo
        using (_logger.BeginScope(new Dictionary<string, object>
        {
            ["CorrelationId"] = correlationId
        }))
        {
            await _proximo(contexto);
        }
    }

    private static string ObterOuGerar(HttpContext contexto)
    {
        if (contexto.Request.Headers.TryGetValue(Cabecalho, out var valores))
        {
            var recebido = valores.ToString();

            // Validar o que vem de fora: o valor vai para o log e para o banco.
            if (!string.IsNullOrWhiteSpace(recebido)
                && recebido.Length <= 64
                && recebido.All(c => char.IsLetterOrDigit(c) || c is '-' or '_'))
            {
                return recebido;
            }
        }

        // Sem cabecalho valido: usa o TraceIdentifier do proprio ASP.NET Core
        return contexto.TraceIdentifier;
    }
}
```

```csharp
// Registre CEDO no pipeline -- antes de qualquer coisa que possa logar
app.UseMiddleware<MiddlewareDeCorrelationId>();
```

> **Valide o valor recebido.** Um correlation ID vindo de fora é entrada de usuário: sem
> limite de tamanho e sem restrição de caracteres, ele vira vetor de poluição de log — e,
> se for concatenado em algum lugar, coisa pior.

---

## Passo 2 — Propagar nas chamadas de saída

```csharp
public sealed class HandlerDeCorrelationId : DelegatingHandler
{
    private readonly IHttpContextAccessor _acessor;

    public HandlerDeCorrelationId(IHttpContextAccessor acessor) => _acessor = acessor;

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage requisicao, CancellationToken cancellationToken)
    {
        var correlationId =
            _acessor.HttpContext?.Items[MiddlewareDeCorrelationId.Cabecalho] as string;

        if (!string.IsNullOrEmpty(correlationId))
        {
            requisicao.Headers.TryAddWithoutValidation(
                MiddlewareDeCorrelationId.Cabecalho, correlationId);
        }

        return base.SendAsync(requisicao, cancellationToken);
    }
}
```

```csharp
builder.Services.AddHttpContextAccessor();
builder.Services.AddTransient<HandlerDeCorrelationId>();

builder.Services
    .AddHttpClient<ClienteFiscal>()
    .AddHttpMessageHandler<HandlerDeCorrelationId>()
    .AddStandardResilienceHandler();
```

O handler roda **antes** da resiliência, então todas as retentativas saem com o mesmo
correlation ID — exatamente o que se quer para ver a sequência completa no log.

Veja [`../httpclient/resiliencia-retry-circuit-breaker.md`](../httpclient/resiliencia-retry-circuit-breaker.md).

---

## Passo 3 — O padrão W3C: `traceparent`

`X-Correlation-Id` é convenção, não padrão. O padrão é o **W3C Trace Context**, com o
cabeçalho `traceparent` — e o .NET moderno já o usa por conta própria.

```text
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             ^  ^                                ^                ^
             |  trace-id (a operacao inteira)    span-id          flags
             versao
```

No .NET, isso aparece como `System.Diagnostics.Activity`:

```csharp
// O ASP.NET Core cria uma Activity por requisicao e o HttpClient propaga
// o traceparent automaticamente -- sem nenhum codigo seu.
var traceId = Activity.Current?.TraceId.ToString();
var spanId  = Activity.Current?.SpanId.ToString();
```

```csharp
// Enriquecer o log com o TraceId do W3C
builder.Host.UseSerilog((contexto, config) => config
    .Enrich.FromLogContext()
    .Enrich.WithProperty("Aplicacao", "<NOME-DO-SISTEMA>")
    .Enrich.With<EnriquecedorDeTrace>());

public sealed class EnriquecedorDeTrace : ILogEventEnricher
{
    public void Enrich(LogEvent evento, ILogEventPropertyFactory fabrica)
    {
        var atividade = Activity.Current;
        if (atividade is null) return;

        evento.AddPropertyIfAbsent(
            fabrica.CreateProperty("TraceId", atividade.TraceId.ToString()));
        evento.AddPropertyIfAbsent(
            fabrica.CreateProperty("SpanId", atividade.SpanId.ToString()));
    }
}
```

### Qual usar

| Situação | Escolha |
|---|---|
| Tudo é .NET moderno e você tem (ou terá) uma plataforma de observabilidade | **`traceparent` / `Activity`** — é o padrão e já funciona sozinho |
| Há sistemas legados, parceiros externos ou gateways no caminho | **`X-Correlation-Id`** — simples, legível e todo mundo aceita |
| Realidade da maioria | **Os dois.** `traceparent` para as ferramentas, `X-Correlation-Id` para as pessoas |

Manter os dois custa pouco: um cabeçalho a mais e um campo a mais no log.

---

## Passo 4 — Levar o rastro até o SQL Server

Este é o passo que quase ninguém dá, e o que fecha o ciclo. Sem ele, você consegue seguir a
requisição entre serviços, mas quando o problema está no banco a trilha some.

### O básico: `Application Name`

```text
Server=<SERVIDOR>;Database=<BANCO>;...;Application Name=<NOME-DO-SISTEMA>
```

Preencha isso e a coluna `program_name` das DMVs passa a dizer **de quem** é cada sessão.
É o pré-requisito de qualquer investigação de banco:
[`../../sql-server/monitoramento/sessoes-e-requests-em-execucao.sql`](../../sql-server/monitoramento/sessoes-e-requests-em-execucao.sql).

### O avançado: `sp_set_session_context` (SQL Server 2016+)

Dá para carimbar o correlation ID **na própria sessão do banco**:

```csharp
public static async Task MarcarSessaoAsync(
    SqlConnection conexao, string correlationId, CancellationToken ct)
{
    // read_only = 1 impede que o valor seja alterado depois na mesma sessao.
    await using var comando = new SqlCommand(
        "EXEC sys.sp_set_session_context @key = N'CorrelationId', " +
        "@value = @valor, @read_only = 1;", conexao);

    comando.Parameters.Add("@valor", SqlDbType.NVarChar, 128).Value = correlationId;

    await comando.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
}
```

E, do lado do banco, durante um incidente:

```sql
/* Quem esta bloqueando quem -- agora com o correlation ID da aplicacao */
SELECT
    bloqueador     = r.blocking_session_id,
    bloqueado      = r.session_id,
    esperando_seg  = r.wait_time / 1000,
    r.wait_type,
    programa       = s.program_name,
    correlation_id = CONVERT(NVARCHAR(128), SESSION_CONTEXT(N'CorrelationId')),
    banco          = DB_NAME(r.database_id)
FROM sys.dm_exec_requests AS r
INNER JOIN sys.dm_exec_sessions AS s
        ON s.session_id = r.session_id
WHERE r.blocking_session_id <> 0
  AND r.blocking_session_id <> r.session_id;
```

> `SESSION_CONTEXT()` só enxerga o valor da **própria sessão**. Para consultar o valor de
> outras sessões a partir de uma sessão de diagnóstico, o caminho é capturar por Extended
> Events, ou gravar o par (`session_id`, `CorrelationId`) em uma tabela de apoio no início
> da operação. Avalie o custo antes de adotar em caminho de alta frequência.

**Custos a considerar:** cada `sp_set_session_context` é um *round trip* extra ao banco, e
com pooling de conexão o contexto acompanha a conexão reaproveitada. Vale para operações
relevantes de negócio, não para toda consulta de tela.

Em SQL Server 2012/2014, o equivalente aproximado é `SET CONTEXT_INFO`, que aceita apenas
um `VARBINARY(128)` único — menos flexível, mas suficiente para carregar um GUID.

---

## O ciclo completo

```text
[Navegador]
   |  X-Correlation-Id: 7f3a1b   (ou traceparent)
   v
[API Pedidos] --- log: corr=7f3a1b, PedidoId=48213
   |
   |--> [SQL Server]  program_name = 'ERP-Pedidos'
   |                  SESSION_CONTEXT('CorrelationId') = 7f3a1b
   |
   `--> [API Fiscal]  X-Correlation-Id: 7f3a1b
            |         log: corr=7f3a1b, Timeout no SEFAZ
            v
        [SEFAZ]
```

Uma consulta por `7f3a1b` atravessa aplicação, integração e banco.

---

## Devolver o identificador ao usuário

```csharp
return Problem(
    title:    "Nao foi possivel concluir a operacao.",
    statusCode: StatusCodes.Status500InternalServerError,
    extensions: new Dictionary<string, object?>
    {
        ["correlationId"] = HttpContext.Items[MiddlewareDeCorrelationId.Cabecalho]
    });
```

A tela mostra: *"Erro ao processar. Código: 7f3a1b"*. O usuário informa o código ao
suporte, e o suporte encontra o erro exato em segundos — sem expor stack trace, caminho de
arquivo ou nome de servidor.

Veja [`../excecoes/tratamento-de-excecoes.md`](../excecoes/tratamento-de-excecoes.md).

---

## .NET Framework

Sem middleware do ASP.NET Core, o lugar equivalente é o `Global.asax`:

```csharp
protected void Application_BeginRequest(object sender, EventArgs e)
{
    var recebido = Request.Headers["X-Correlation-Id"];

    var correlationId = !string.IsNullOrWhiteSpace(recebido) && recebido.Length <= 64
        ? recebido
        : Guid.NewGuid().ToString("N");

    HttpContext.Current.Items["CorrelationId"] = correlationId;
    Response.Headers["X-Correlation-Id"] = correlationId;
}
```

> **Cuidado com `HttpContext.Current` em código assíncrono.** Depois de um `await` com
> `ConfigureAwait(false)`, ele pode ser `null`. Capture o correlation ID em uma variável
> local **antes** do primeiro `await` e passe adiante explicitamente. Veja
> [`../async-await/armadilhas-async-await.md`](../async-await/armadilhas-async-await.md).

Para propagar, `Application Name` na connection string funciona igual, e o handler de
`HttpClient` também — `DelegatingHandler` existe no .NET Framework.

---

## Checklist

- [ ] Correlation ID gerado ou aceito na borda, com **validação** do valor recebido.
- [ ] Middleware registrado cedo no pipeline.
- [ ] Escopo de log criado com o identificador, cobrindo a requisição inteira.
- [ ] Propagado em toda chamada HTTP de saída, **antes** da camada de resiliência.
- [ ] Devolvido no cabeçalho de resposta e na resposta de erro.
- [ ] `Application Name` preenchido na connection string.
- [ ] `sp_set_session_context` avaliado para as operações críticas (SQL Server 2016+).
- [ ] `traceparent` preservado quando houver plataforma de observabilidade.
- [ ] O identificador **não** carrega dado de negócio nem dado pessoal.

## Referências

- [W3C Trace Context](https://www.w3.org/TR/trace-context/)
- [Rastreamento distribuído no .NET](https://learn.microsoft.com/pt-br/dotnet/core/diagnostics/distributed-tracing)
- [`Activity` e `ActivitySource`](https://learn.microsoft.com/pt-br/dotnet/core/diagnostics/distributed-tracing-instrumentation-walkthroughs)
- [`sp_set_session_context`](https://learn.microsoft.com/pt-br/sql/relational-databases/system-stored-procedures/sp-set-session-context-transact-sql)
- [`SESSION_CONTEXT`](https://learn.microsoft.com/pt-br/sql/t-sql/functions/session-context-transact-sql)

---

**Criado por Fábio Cerqueira**
