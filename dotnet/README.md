# C# e .NET

> Foco em erros que custam caro em produção, não em sintaxe. `HttpClient` mal usado,
> `async` bloqueado com `.Result`, exceção transitória tratada como permanente, data sem
> fuso.

---

## Documentos

### `HttpClient`

| Documento | Assunto |
|---|---|
| [`httpclient/httpclient-uso-correto.md`](httpclient/httpclient-uso-correto.md) | Esgotamento de sockets, DNS obsoleto, `IHttpClientFactory`, caminho para .NET Framework |
| [`httpclient/timeout-e-cancellation.md`](httpclient/timeout-e-cancellation.md) | Os quatro timeouts da cadeia e por que aumentar o timeout piora tudo |
| [`httpclient/resiliencia-retry-circuit-breaker.md`](httpclient/resiliencia-retry-circuit-breaker.md) | Polly v8 e v7, backoff com jitter, circuit breaker |

### Linguagem e runtime

| Documento | Assunto |
|---|---|
| [`async-await/armadilhas-async-await.md`](async-await/armadilhas-async-await.md) | Deadlock em ASP.NET clássico, `async void`, `Task.Run` indevido, `ConfigureAwait` |
| [`excecoes/tratamento-de-excecoes.md`](excecoes/tratamento-de-excecoes.md) | O que capturar, `throw` x `throw ex`, transitório x permanente, log seguro |
| [`json/serializacao-json.md`](json/serializacao-json.md) | `System.Text.Json` x `Newtonsoft.Json`, fuso, cultura, DTOs |

### Diagnóstico

| Documento | Assunto |
|---|---|
| [`diagnostico/aplicacao-lenta-ou-travando.md`](diagnostico/aplicacao-lenta-ou-travando.md) | Roteiro por padrão de CPU e memória, thread pool starvation, dumps |

---

## Os cinco erros que derrubam aplicação em produção

| # | Erro | Sintoma | Documento |
|---|---|---|---|
| 1 | `using (var client = new HttpClient())` | Esgotamento de portas sob carga | [`httpclient/httpclient-uso-correto.md`](httpclient/httpclient-uso-correto.md) |
| 2 | `.Result` / `.Wait()` | Deadlock em ASP.NET clássico; thread starvation no Core | [`async-await/armadilhas-async-await.md`](async-await/armadilhas-async-await.md) |
| 3 | `catch (Exception) { }` | Dado corrompido descoberto meses depois | [`excecoes/tratamento-de-excecoes.md`](excecoes/tratamento-de-excecoes.md) |
| 4 | `DateTime` sem fuso | Diferença de horas em relatório de fechamento | [`json/serializacao-json.md`](json/serializacao-json.md) |
| 5 | Retry sem idempotência | Operação duplicada | [`../api-integracao/resiliencia/retry-seguro-e-idempotencia.md`](../api-integracao/resiliencia/retry-seguro-e-idempotencia.md) |

---

## Compatibilidade

| Plataforma | Situação | Onde aparece neste repositório |
|---|---|---|
| .NET Framework 4.6.2 – 4.8.1 | Suportada; segue o ciclo do Windows | WebForms, MVC 5, WCF, EF6 |
| .NET 8 (LTS) | Fim de suporte em **10/11/2026** | Base instalada grande |
| .NET 9 (STS) | Fim de suporte em **10/11/2026** | |
| .NET 10 (LTS) | LTS atual, suporte até novembro de 2028 | Alvo recomendado para código novo |

Quando há diferença relevante de comportamento, os documentos apresentam o caminho na
ordem **Legado → Intermediário → Moderno**, em vez de fingir que a solução moderna se
aplica a tudo.

Dois pontos que separam as plataformas com mais frequência:

- **`SynchronizationContext`**: existe em ASP.NET clássico, WinForms e WPF; não existe em
  ASP.NET Core. É o que faz `.Result` travar em um e apenas degradar no outro.
- **TLS**: em .NET Framework 4.6.x é preciso habilitar TLS 1.2 explicitamente; no .NET
  moderno, o padrão vem do sistema operacional.

---

## Áreas relacionadas

- [`../acesso-a-dados/`](../acesso-a-dados/) — ADO.NET, Dapper, EF Core, EF6
- [`../api-integracao/`](../api-integracao/) — resiliência, SOAP, autenticação
- [`../iis/`](../iis/) — onde a aplicação é hospedada
- [`../sistemas-legados/`](../sistemas-legados/) — manter e modernizar o que já existe

---

**Criado por Fábio Cerqueira**
