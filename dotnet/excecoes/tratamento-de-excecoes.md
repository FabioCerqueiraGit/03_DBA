# Tratamento de exceções — o que capturar, o que deixar subir

> A maior parte do código de tratamento de exceção que se encontra em produção piora o
> diagnóstico em vez de melhorá-lo: engole o erro, perde o stack trace, ou repete o que não
> deveria ser repetido.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8 · .NET 10 |
| **Impacto** | Exceção engolida vira dado corrompido descoberto meses depois |

---

## A regra

> **Só capture uma exceção se você vai fazer alguma coisa com ela.**

"Alguma coisa" é: tratar de verdade, traduzir para um erro de domínio, registrar com
contexto que o chamador não teria, ou repetir uma operação comprovadamente transitória.

Registrar e relançar em todas as camadas **não** conta: gera o mesmo erro cinco vezes no
log e não acrescenta informação.

---

## Os quatro erros clássicos

### 1. Engolir

```csharp
// ❌ O pior codigo possivel: o erro acontece e ninguem fica sabendo
try
{
    await _servico.ProcessarAsync(pedido, ct);
}
catch (Exception)
{
    // ignorado
}
```

O sistema continua rodando com estado inconsistente. O problema aparece semanas depois,
como dado errado, sem nenhum rastro que leve até aqui.

### 2. Perder o stack trace

```csharp
// ❌ throw ex REINICIA o stack trace na linha do catch.
//    A origem real do erro e perdida.
catch (Exception ex)
{
    _logger.LogError(ex, "Falhou");
    throw ex;
}

// ✅ throw preserva o stack trace original
catch (Exception ex)
{
    _logger.LogError(ex, "Falha ao processar o pedido {PedidoId}", pedido.Id);
    throw;
}
```

A diferença entre `throw ex` e `throw` é uma palavra e a capacidade de diagnosticar.

Quando for necessário relançar uma exceção capturada fora do `catch` original, use
`ExceptionDispatchInfo.Capture(ex).Throw()`, que preserva o rastro.

### 3. Capturar largo demais

```csharp
// ❌ Captura tudo, inclusive o que nao deveria ser tratado aqui
catch (Exception ex)
{
    return new Resultado { Sucesso = false, Mensagem = "Erro ao consultar." };
}

// ✅ Capture o que voce sabe tratar
catch (HttpRequestException ex)
{
    _logger.LogWarning(ex, "API indisponivel ao consultar {Id}", id);
    return Resultado.Indisponivel();
}
catch (TaskCanceledException ex) when (ex.InnerException is TimeoutException)
{
    _logger.LogWarning(ex, "Timeout ao consultar {Id}", id);
    return Resultado.Timeout();
}
```

Capturar `Exception` faz você engolir também `OutOfMemoryException`,
`StackOverflowException` e erros de programação como `NullReferenceException` — que
deveriam derrubar a operação, não virar "Erro ao consultar".

### 4. Filtro de exceção mal usado

```csharp
// ✅ O filtro `when` avalia ANTES de desenrolar a pilha.
//    Isso preserva o estado no dump e evita capturar o que nao interessa.
catch (SqlException ex) when (ex.Number == 1205)
{
    // deadlock: vale retry
}
catch (SqlException ex) when (ex.Number == 2627)
{
    // violacao de chave: nao vale retry, e um caso de negocio
}
```

O `when` é preferível a capturar e relançar dentro do bloco: além de mais claro, a pilha
não é desenrolada quando o filtro não casa — o que preserva informação valiosa em um dump.

---

## Transitório, permanente, indeterminado

A mesma classificação que vale para integração vale aqui:

```csharp
public static bool EhTransitorio(SqlException ex) => ex.Number switch
{
    1205  => true,   // deadlock victim
    -2    => true,   // timeout
    1204  => true,   // sem recursos de lock
    701   => true,   // memoria insuficiente no servidor
    40197 => true,   // Azure SQL: erro de processamento
    40501 => true,   // Azure SQL: servico ocupado
    40613 => true,   // Azure SQL: banco indisponivel
    49918 => true,   // Azure SQL: sem recursos
    _     => false
};
```

| Erro | Classificação | Ação |
|---|---|---|
| 1205 (deadlock) | Transitória | Retry com backoff **e jitter** |
| -2 (timeout) | Transitória, mas cuidado | Retry **só se idempotente** — pode ter sido executado |
| 2627 / 2601 (chave duplicada) | Permanente | Não repetir. Frequentemente é caso de negócio, não erro |
| 547 (violação de constraint) | Permanente | Corrigir o dado ou a regra |
| 208 (objeto inexistente) | Permanente | Erro de deploy ou de permissão |

O caso do timeout é o mesmo dilema das integrações: você não sabe se o comando foi
executado. Ver
[`../../api-integracao/resiliencia/retry-seguro-e-idempotencia.md`](../../api-integracao/resiliencia/retry-seguro-e-idempotencia.md).

---

## Exceções de domínio

```csharp
// Erro esperado do negocio: nao e falha tecnica
public sealed class PedidoJaFaturadoException : Exception
{
    public int PedidoId { get; }

    public PedidoJaFaturadoException(int pedidoId)
        : base($"O pedido {pedidoId} ja foi faturado e nao pode ser alterado.")
        => PedidoId = pedidoId;
}
```

Duas orientações que evitam problemas:

**1. Não use exceção para fluxo esperado de alta frequência.** Lançar exceção é caro. Se
"pedido não encontrado" acontece a cada segunda requisição, retorne um resultado que
representa isso, não uma exceção.

**2. A mensagem de exceção de domínio pode chegar ao usuário; a mensagem técnica, não.**
Escreva as duas de forma diferente.

---

## Tratamento global

### ASP.NET Core

```csharp
app.UseExceptionHandler(builder =>
{
    builder.Run(async contexto =>
    {
        var feature = contexto.Features.Get<IExceptionHandlerFeature>();
        var excecao = feature?.Error;

        var logger = contexto.RequestServices
                             .GetRequiredService<ILogger<Program>>();

        logger.LogError(excecao,
            "Erro nao tratado em {Metodo} {Caminho}. TraceId {TraceId}",
            contexto.Request.Method,
            contexto.Request.Path,
            contexto.TraceIdentifier);

        contexto.Response.StatusCode  = excecao switch
        {
            PedidoJaFaturadoException => StatusCodes.Status409Conflict,
            UnauthorizedAccessException => StatusCodes.Status403Forbidden,
            _ => StatusCodes.Status500InternalServerError
        };

        contexto.Response.ContentType = "application/problem+json";

        // Nunca exponha stack trace ao cliente. O TraceId liga o erro ao log.
        await contexto.Response.WriteAsJsonAsync(new ProblemDetails
        {
            Status   = contexto.Response.StatusCode,
            Title    = "Nao foi possivel concluir a operacao.",
            Instance = contexto.Request.Path,
            Extensions = { ["traceId"] = contexto.TraceIdentifier }
        });
    });
});
```

Devolver o `traceId` ao cliente é o detalhe que transforma o suporte: o usuário informa o
código, e você encontra o erro exato no log em segundos — sem expor nada de sensível.

### .NET Framework (Global.asax)

```csharp
protected void Application_Error(object sender, EventArgs e)
{
    var excecao = Server.GetLastError();

    // Registre ANTES de Server.ClearError(), ou a informacao se perde
    Logger.Error(excecao, "Erro nao tratado em {0}", Request.Url);
}
```

---

## O que registrar, e o que nunca registrar

```csharp
// ✅ Contexto que permite reproduzir
_logger.LogError(ex,
    "Falha ao processar pedido {PedidoId} do cliente {ClienteId}. Correlation {CorrelationId}",
    pedido.Id, pedido.ClienteId, correlationId);
```

| Registre | Nunca registre |
|---|---|
| Identificadores (pedido, cliente, correlação) | Senha, token, chave de API |
| Operação e etapa | Número completo de cartão |
| A exceção completa, com `InnerException` | Documento completo, dado de saúde |
| Timestamp em UTC | Corpo inteiro de requisição com dado pessoal |

Use **log estruturado** (`{PedidoId}` como parâmetro nomeado, não interpolação): assim dá
para filtrar por campo depois, em vez de procurar texto.

> Log é lido por muita gente e vive muito tempo. Trate-o como um sistema com controle de
> acesso próprio, porque é isso que ele é.

---

## Checklist

- [ ] Nenhum `catch` vazio.
- [ ] `throw`, nunca `throw ex`.
- [ ] Exceções específicas capturadas; `Exception` só no tratador global.
- [ ] Filtros `when` para distinguir casos.
- [ ] Erros transitórios e permanentes classificados.
- [ ] Retry apenas para transitórios — e para timeout, só com idempotência.
- [ ] Tratador global registrando com contexto.
- [ ] `traceId` devolvido ao cliente; stack trace, não.
- [ ] Nenhum dado sensível em log.
- [ ] Log estruturado, com parâmetros nomeados.

## Referências

- [Melhores práticas para exceções](https://learn.microsoft.com/pt-br/dotnet/standard/exceptions/best-practices-for-exceptions)
- [Tratar erros no ASP.NET Core](https://learn.microsoft.com/pt-br/aspnet/core/fundamentals/error-handling)
- [Log no .NET](https://learn.microsoft.com/pt-br/dotnet/core/extensions/logging)

---

**Criado por Fábio Cerqueira**
