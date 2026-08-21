# Retry seguro e idempotência — repetir sem duplicar

> Retry é a primeira coisa que se adiciona a uma integração instável, e a que mais causa
> incidente de dado. O problema não é repetir: é repetir **o que não pode ser repetido**.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8 · .NET 10 |
| **Impacto** | Retry sem idempotência gera duplicidade em produção — e duplicidade financeira é incidente grave |

---

## O problema em uma frase

```text
Cliente ----- POST /pagamentos ----->  Servidor
                                       processa, debita R$ 1.000
       <---- (resposta se perde) -----
Timeout no cliente.

O cliente repete.  O servidor debita R$ 1.000 de novo.
```

O cliente **não tem como saber** se o servidor processou. Timeout não significa "nada
aconteceu": significa "não sei o que aconteceu".

A solução não é desistir do retry — falha de rede é normal. A solução é fazer com que
**repetir não cause efeito adicional**.

---

## Idempotência, na prática

Uma operação é idempotente quando executá-la N vezes produz o mesmo estado final que
executá-la uma vez.

| Método HTTP | Idempotente por definição? |
|---|---|
| `GET`, `HEAD`, `OPTIONS` | Sim (não alteram estado) |
| `PUT` | Sim — define o estado, não incrementa |
| `DELETE` | Sim — apagar duas vezes deixa apagado |
| **`POST`** | **Não** — e é justamente onde estão as operações de negócio |
| `PATCH` | Depende do conteúdo |

> "Idempotente" **não é** o mesmo que "sem efeito colateral". Um `PUT` pode gravar log,
> disparar evento e enviar e-mail. O que importa é que o **estado final** seja o mesmo.

---

## Estratégia 1 — Chave de idempotência (para APIs que você consome)

O cliente gera um identificador único da **tentativa de operação** e o repete em todas as
retentativas.

```csharp
// A chave e gerada UMA VEZ, fora do laco de retry.
// Gerar dentro do laco anularia todo o mecanismo.
var chaveDeIdempotencia = Guid.NewGuid().ToString("N");

using var requisicao = new HttpRequestMessage(HttpMethod.Post, "v1/pagamentos")
{
    Content = JsonContent.Create(pagamento)
};

requisicao.Headers.TryAddWithoutValidation("Idempotency-Key", chaveDeIdempotencia);

using var resposta = await _pipeline
    .ExecuteAsync(async ct => await _http.SendAsync(requisicao, ct), cancellationToken)
    .ConfigureAwait(false);
```

> **Detalhe que quebra o retry:** um `HttpRequestMessage` **não pode ser reenviado**. Ao
> repetir, monte uma nova instância com a **mesma** chave. Uma fábrica dentro do
> `ExecuteAsync` resolve isso:
>
> ```csharp
> await _pipeline.ExecuteAsync(async ct =>
> {
>     using var req = CriarRequisicao(pagamento, chaveDeIdempotencia);
>     return await _http.SendAsync(req, ct);
> }, cancellationToken);
> ```

`Idempotency-Key` é o nome de cabeçalho mais difundido, adotado por diversas APIs de
pagamento. **Confirme na documentação do parceiro** qual nome ele espera — não é um padrão
universal.

---

## Estratégia 2 — Implementar idempotência na API que você expõe

```csharp
[HttpPost("pagamentos")]
public async Task<IActionResult> Criar(
    [FromBody] PagamentoRequest requisicao,
    [FromHeader(Name = "Idempotency-Key")] string? chave,
    CancellationToken cancellationToken)
{
    if (string.IsNullOrWhiteSpace(chave))
        return BadRequest(new { erro = "Cabecalho Idempotency-Key e obrigatorio." });

    // 1. Ja processamos esta chave?
    var registro = await _repositorio.ObterPorChaveAsync(chave, cancellationToken);

    if (registro is not null)
    {
        // 1a. Mesma chave com corpo DIFERENTE = erro do cliente, nao repeticao.
        if (registro.HashDaRequisicao != CalcularHash(requisicao))
            return Conflict(new { erro = "Idempotency-Key ja usada com outro conteudo." });

        // 1b. Repeticao legitima: devolve o MESMO resultado, sem reprocessar.
        return Ok(registro.Resposta);
    }

    // 2. Processa e grava o resultado NA MESMA TRANSACAO do efeito de negocio.
    var resultado = await _servico.ProcessarAsync(requisicao, chave, cancellationToken);

    return Ok(resultado);
}
```

### O detalhe que faz a coisa funcionar de verdade

A gravação do registro de idempotência e o efeito de negócio precisam estar **na mesma
transação**. Se forem separados, existe uma janela em que o pagamento foi debitado e a
chave ainda não foi registrada — e a repetição duplica.

```sql
/* Tabela de idempotencia. A UNIQUE na chave e o que garante a exclusao mutua
   sob concorrencia: duas requisicoes simultaneas com a mesma chave, e uma
   delas falha com violacao de chave -- o que e o comportamento desejado. */
CREATE TABLE dbo.RegistroDeIdempotencia
(
    Chave              VARCHAR(64)   NOT NULL,
    HashDaRequisicao   BINARY(32)    NOT NULL,
    Resposta           NVARCHAR(MAX) NULL,
    CriadoEm           DATETIME2(3)  NOT NULL
                       CONSTRAINT DF_RegistroDeIdempotencia_CriadoEm DEFAULT SYSUTCDATETIME(),
    ExpiraEm           DATETIME2(3)  NOT NULL,

    CONSTRAINT PK_RegistroDeIdempotencia PRIMARY KEY CLUSTERED (Chave)
);
GO

/* Indice para a rotina de expurgo */
CREATE NONCLUSTERED INDEX IX_RegistroDeIdempotencia_ExpiraEm
    ON dbo.RegistroDeIdempotencia (ExpiraEm);
GO
```

Defina uma **retenção** (24 a 72 horas costuma bastar) e um job de expurgo em lotes — sem
isso a tabela cresce sem limite.

---

## Estratégia 3 — Idempotência por identificador de negócio

Nem toda API aceita cabeçalho de idempotência. Quando existe um identificador natural da
operação — número do pedido, número da nota, código do lote — ele serve:

```sql
/* A UNIQUE faz o trabalho: a segunda tentativa falha com 2627,
   e o codigo trata isso como "ja processado". */
CREATE UNIQUE NONCLUSTERED INDEX UX_Pagamento_NumeroDoPedido
    ON dbo.Pagamento (NumeroDoPedido);
```

```csharp
try
{
    await _repositorio.InserirAsync(pagamento, cancellationToken);
}
catch (SqlException ex) when (ex.Number is 2601 or 2627)
{
    // 2601/2627 = violacao de indice unico / chave.
    // Nao e erro: e a segunda tentativa da MESMA operacao.
    _logger.LogInformation(
        "Pagamento do pedido {Pedido} ja registrado; ignorando duplicata.",
        pagamento.NumeroDoPedido);

    return await _repositorio.ObterPorPedidoAsync(pagamento.NumeroDoPedido, cancellationToken);
}
```

Deixar o banco garantir a unicidade é mais confiável do que verificar antes de inserir:
entre a verificação e a inserção há uma janela de concorrência. A constraint não tem
janela.

---

## Classificar a falha antes de decidir

```csharp
public enum TipoDeFalha
{
    Transitoria,      // repetir resolve
    Permanente,       // repetir nao muda nada
    Indeterminada     // NAO SE SABE se o servidor processou
}

public static TipoDeFalha Classificar(HttpResponseMessage? resposta, Exception? excecao)
{
    if (excecao is TaskCanceledException or TimeoutException)
        return TipoDeFalha.Indeterminada;      // o pedido pode ter chegado

    if (excecao is HttpRequestException { InnerException: SocketException se }
        && se.SocketErrorCode is SocketError.HostNotFound
                              or SocketError.ConnectionRefused)
        return TipoDeFalha.Transitoria;        // nem chegou a conectar

    if (resposta is null)
        return TipoDeFalha.Indeterminada;

    var codigo = (int)resposta.StatusCode;

    return codigo switch
    {
        >= 500          => TipoDeFalha.Transitoria,
        408 or 429      => TipoDeFalha.Transitoria,
        >= 400          => TipoDeFalha.Permanente,
        _               => TipoDeFalha.Transitoria
    };
}
```

| Classificação | Ação |
|---|---|
| **Transitória** | Repetir com backoff e jitter |
| **Permanente** | Não repetir. Registrar, alertar, encaminhar para tratamento |
| **Indeterminada** | Repetir **somente** se a operação for idempotente. Caso contrário, consultar o estado antes |

### Consultar antes de repetir

Quando a operação não é idempotente e a falha é indeterminada, a saída é perguntar:

```csharp
// Timeout em operacao nao idempotente: consulte o estado antes de repetir
var existente = await _api.ConsultarPorReferenciaAsync(referencia, cancellationToken);

if (existente is not null)
    return existente;          // ja tinha sido processado

return await _api.CriarAsync(pagamento, cancellationToken);
```

Isso exige que a API ofereça consulta por referência do cliente. Se ela não oferece,
exija isso no contrato — sem consulta e sem idempotência, não existe integração confiável.

---

## Reconciliação — o que fecha a conta

Toda integração assíncrona precisa de um processo que compare os dois lados e corrija
divergências. Sem ele, você descobre o problema pelo cliente.

```text
Diariamente:
  1. listar as operacoes do dia no SEU sistema
  2. listar as operacoes do dia no sistema PARCEIRO
  3. comparar por identificador de negocio
  4. classificar as divergencias:
       - existe aqui e nao la  -> reenviar
       - existe la e nao aqui  -> importar ou investigar
       - existe nos dois com valores diferentes -> ALERTA, tratamento manual
  5. registrar o resultado, mesmo quando nao ha divergencia
```

O passo 5 importa: um relatório que diz "zero divergências" é a prova de que a
reconciliação rodou. Sem ele, não dá para distinguir "está tudo certo" de "o job parou
semana passada".

---

## Observabilidade mínima

```csharp
// Correlation ID atravessa toda a cadeia, incluindo as retentativas
requisicao.Headers.TryAddWithoutValidation("X-Correlation-Id", correlationId);

_logger.LogInformation(
    "Enviando {Operacao} ref {Referencia}. Tentativa {Tentativa}. Correlation {CorrelationId}",
    nomeDaOperacao, referencia, tentativa, correlationId);
```

**O que nunca deve ir para o log:** token, senha, número completo de cartão, documento
completo, corpo com dado pessoal. Registre o identificador, não o conteúdo.

---

## Checklist

- [ ] Falhas classificadas em transitória, permanente e **indeterminada**.
- [ ] Retry apenas para transitória e para indeterminada **com idempotência**.
- [ ] Backoff exponencial com **jitter**.
- [ ] `Retry-After` respeitado em HTTP 429.
- [ ] Chave de idempotência gerada **fora** do laço de retry.
- [ ] Nova instância de `HttpRequestMessage` a cada tentativa, com a mesma chave.
- [ ] Registro de idempotência gravado na **mesma transação** do efeito de negócio.
- [ ] Constraint `UNIQUE` como garantia final de não duplicidade.
- [ ] Retenção e expurgo da tabela de idempotência definidos.
- [ ] Processo de reconciliação rodando **e** registrando execução.
- [ ] Correlation ID propagado; dado sensível fora do log.

## Referências

- [Padrão de repetição (Retry)](https://learn.microsoft.com/pt-br/azure/architecture/patterns/retry)
- [Padrão Circuit Breaker](https://learn.microsoft.com/pt-br/azure/architecture/patterns/circuit-breaker)
- [Resiliência HTTP no .NET](https://learn.microsoft.com/pt-br/dotnet/core/resilience/http-resilience)
- [`../../dotnet/httpclient/resiliencia-retry-circuit-breaker.md`](../../dotnet/httpclient/resiliencia-retry-circuit-breaker.md)

---

**Criado por Fábio Cerqueira**
