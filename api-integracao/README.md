# APIs e integração de sistemas

> Integração é onde os sistemas se encontram e onde os problemas se escondem. Esta área
> trata do que fazer quando o outro lado falha, demora, responde errado — ou responde duas
> vezes.

---

## Documentos

| Documento | Assunto |
|---|---|
| [`resiliencia/retry-seguro-e-idempotencia.md`](resiliencia/retry-seguro-e-idempotencia.md) | Repetir sem duplicar: chave de idempotência, classificação de falha, reconciliação |
| [`soap-wcf/consumir-soap-de-sistema-legado.md`](soap-wcf/consumir-soap-de-sistema-legado.md) | SOAP e WCF do .NET Framework ao .NET 10, com os erros clássicos |
| [`autenticacao/autenticacao-em-apis.md`](autenticacao/autenticacao-em-apis.md) | API Key, Basic, JWT, OAuth 2.0 client credentials, mTLS |

Para o cliente HTTP em si — criação, reuso, timeout, Polly — veja
[`../dotnet/httpclient/`](../dotnet/httpclient/).

---

## As três perguntas de toda integração

Antes de escrever a primeira linha:

**1. O que acontece se o outro lado não responder?**
Timeout definido, retry classificado, circuit breaker, e um caminho de degradação.

**2. O que acontece se eu enviar duas vezes?**
Se a resposta for "duplica o pedido", a integração não está pronta. Idempotência vem antes
do retry, não depois.

**3. Como eu descubro que ficou fora de sincronia?**
Reconciliação periódica. Sem ela, quem descobre a divergência é o cliente.

---

## Classificação de falha — a tabela que resolve a maior parte das dúvidas

| Situação | Classificação | Repetir? |
|---|---|---|
| HTTP 500, 502, 503, 504 | Transitória | Sim |
| HTTP 429 | Transitória | Sim, respeitando `Retry-After` |
| HTTP 408 | Transitória | Sim |
| Falha de conexão (DNS, recusa) | Transitória | Sim — nem chegou a enviar |
| **Timeout após envio** | **Indeterminada** | Só com idempotência |
| HTTP 400, 401, 403, 404, 422 | Permanente | Não |

O caso do meio é o que causa incidente de dado. Detalhes em
[`resiliencia/retry-seguro-e-idempotencia.md`](resiliencia/retry-seguro-e-idempotencia.md).

---

## Síncrono ou assíncrono

| | Síncrono | Assíncrono (fila, webhook, polling) |
|---|---|---|
| **Use quando** | O chamador precisa da resposta para continuar | O trabalho pode ser concluído depois |
| **Falha do destino** | Derruba a operação inteira | A mensagem espera |
| **Pico de carga** | Propaga direto | A fila absorve |
| **Complexidade** | Baixa | Alta — exige idempotência, ordem, *dead letter* |
| **Rastreabilidade** | Imediata | Exige correlation ID disciplinado |

A maioria das integrações de negócio (emitir nota, enviar pedido, notificar parceiro) não
precisa ser síncrona — e sofre muito por ser.

---

## Observabilidade mínima

| Item | Por quê |
|---|---|
| **Correlation ID** propagado ponta a ponta | Sem ele, correlacionar log dos dois lados é impossível |
| Log de cada tentativa, com número e motivo | Retry silencioso esconde a degradação até virar queda |
| Alerta na abertura do circuit breaker | O sistema para de chamar o parceiro sem erro visível |
| Registro da execução da reconciliação, mesmo sem divergência | Distingue "tudo certo" de "o job parou" |
| **Nada** de token, senha ou dado pessoal em log | Log é lido por muita gente e vive muito tempo |

---

## Áreas relacionadas

- [`../dotnet/httpclient/`](../dotnet/httpclient/) — o cliente HTTP em si
- [`../sistemas-legados/`](../sistemas-legados/) — legado consumindo API moderna
- [`../iis/`](../iis/) — quando a API que você expõe é quem falha

---

**Criado por Fábio Cerqueira**
