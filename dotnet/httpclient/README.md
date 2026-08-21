# .NET — `HttpClient`

> A classe mais usada e mais mal usada do .NET. Três documentos cobrem os problemas que
> aparecem em produção.

| Documento | Assunto |
|---|---|
| [`httpclient-uso-correto.md`](httpclient-uso-correto.md) | Esgotamento de sockets, DNS obsoleto, `IHttpClientFactory` e o caminho para .NET Framework |
| [`timeout-e-cancellation.md`](timeout-e-cancellation.md) | Os quatro timeouts da cadeia, `CancellationToken` e por que aumentar o timeout piora tudo |
| [`resiliencia-retry-circuit-breaker.md`](resiliencia-retry-circuit-breaker.md) | Retry seguro, backoff com jitter, circuit breaker — Polly v8 e Polly v7 |

---

## Os três erros em uma linha cada

1. **`using (var client = new HttpClient())`** → esgota as portas do servidor sob carga.
2. **`static readonly HttpClient` sem reciclagem** → nunca reconsulta o DNS; sobrevive ao
   failover apontando para o IP antigo.
3. **Retry sem idempotência** → duplica a operação quando o timeout ocorre **depois** de o
   servidor ter processado.

---

## Ordem de leitura sugerida

```text
1. httpclient-uso-correto.md          -> como criar e reutilizar corretamente
2. timeout-e-cancellation.md          -> quanto tempo esperar, e como abortar
3. resiliencia-retry-circuit-breaker.md -> o que fazer quando falha
4. ../../api-integracao/resiliencia/retry-seguro-e-idempotencia.md
                                      -> como repetir sem duplicar
```

---

**Criado por Fábio Cerqueira**
