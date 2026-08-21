# [Integração: sistema origem → sistema destino]

> Uma linha sobre o que a integração faz e por que ela existe.

| | |
|---|---|
| **Protocolo** | REST / SOAP / arquivo / fila |
| **Formato** | JSON / XML / CSV / posicional |
| **Modelo** | Síncrono / Assíncrono / Batch |
| **Autenticação** | Basic / Bearer / JWT / OAuth 2.0 / certificado / API key |
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8+ |

---

## Problema

O que precisa fluir entre os dois sistemas e por quê.

## Contrato

Endpoint, verbo, cabeçalhos, corpo de requisição e de resposta. Use `<PLACEHOLDER>` para
host, credencial e identificador real.

```http
POST https://<HOST-DA-API>/v1/pedidos
Authorization: Bearer <TOKEN>
Content-Type: application/json
Idempotency-Key: <GUID>
```

## Implementação

```csharp
```

## Tratamento de falhas

| Situação | Classificação | Ação |
|---|---|---|
| HTTP 5xx | Transitória | Retry com backoff exponencial e jitter |
| HTTP 429 | Transitória | Respeitar `Retry-After` |
| Timeout de rede | **Indeterminada** | Retry apenas se a operação for idempotente |
| HTTP 4xx (exceto 408/429) | Permanente | Não repetir. Registrar e encaminhar |

Timeout é o caso perigoso: você não sabe se o servidor processou. Sem idempotência,
repetir duplica o efeito.

## Idempotência

Como a operação se protege de reprocessamento. Chave de idempotência, deduplicação por
identificador de negócio, ou verificação antes de gravar.

## Observabilidade

- **Correlation ID** propagado em toda a cadeia.
- O que logar: identificador, tentativa, status, latência.
- O que **nunca** logar: token, senha, corpo com dado pessoal.

## Reconciliação

Como detectar e corrigir divergência depois do fato. Toda integração assíncrona precisa
disso; sem reconciliação você só descobre o problema pelo cliente.

## Segurança

TLS, validação de certificado, rotação de credencial, menor privilégio, armazenamento do
segredo.

## Troubleshooting

| Erro | Causa provável | Correção |
|---|---|---|

## Referências

---

**Criado por Fábio Cerqueira**
