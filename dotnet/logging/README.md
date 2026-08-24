# .NET — Logging e observabilidade

> Sistema sem log é caixa-preta. Sistema com log ruim é caixa-preta com barulho. Esta área
> trata de como registrar o que serve para responder perguntas em produção — e de como não
> criar um passivo de privacidade no processo.

---

## Documentos

| Documento | Assunto |
|---|---|
| [`log-estruturado-e-o-que-nunca-logar.md`](log-estruturado-e-o-que-nunca-logar.md) | Message templates, níveis, escopos, `[LoggerMessage]`, provedores e a lista do que nunca registrar |
| [`correlation-id-e-rastreabilidade.md`](correlation-id-e-rastreabilidade.md) | Rastrear uma requisição entre serviços **e até dentro do SQL Server** |

---

## Os três erros que anulam o log

**1. Interpolação de string.**

```csharp
_logger.LogInformation($"Pedido {id} processado");   // vira texto solto
_logger.LogInformation("Pedido {PedidoId} processado", id);   // vira campo consultável
```

**2. Exceção fora do primeiro parâmetro.**

```csharp
_logger.LogError("Erro: " + ex.Message);          // perde stack trace e inner
_logger.LogError(ex, "Falha em {PedidoId}", id);  // grava a cadeia completa
```

**3. Ausência de correlation ID.** Sem ele, cada log é uma ilha e nenhum incidente que
atravessa dois sistemas pode ser reconstruído.

---

## O mínimo que todo sistema precisa

Em ordem de retorno sobre esforço:

1. **`Application Name` na connection string** — uma linha de configuração, e o SQL Server
   passa a dizer qual sistema causou cada problema.
2. **Correlation ID na borda**, propagado em escopo de log.
3. **Log nas fronteiras**: entrada e saída de cada integração externa, com duração.
4. **Log em todo `catch`** que hoje engole erro em silêncio.
5. **Rotação e retenção** configuradas — log sem limite enche o disco do servidor.

Em sistema legado, o item 1 e o item 4 sozinhos já mudam a capacidade de diagnosticar.

---

## Log é sistema com dado sensível

Ele vive muito tempo, é lido por muita gente e raramente tem controle de acesso próprio.
Trate-o como trataria uma tabela de produção: acesso restrito, retenção definida, expurgo
automático — e **nada** de senha, token, documento completo ou dado de saúde dentro.

Os três vazamentos mais silenciosos estão documentados em
[`log-estruturado-e-o-que-nunca-logar.md`](log-estruturado-e-o-que-nunca-logar.md):
`EnableSensitiveDataLogging` do EF Core, rastreamento de mensagens do WCF e exceção de
banco com valores literais.

---

## Áreas relacionadas

- [`../excecoes/tratamento-de-excecoes.md`](../excecoes/tratamento-de-excecoes.md) — o que registrar em cada tipo de falha
- [`../diagnostico/aplicacao-lenta-ou-travando.md`](../diagnostico/aplicacao-lenta-ou-travando.md) — quando o log não basta e é preciso um dump
- [`../../api-integracao/README.md`](../../api-integracao/README.md) — observabilidade de integração
- [`../../sql-server/monitoramento/`](../../sql-server/monitoramento/) — o outro lado da trilha

---

**Criado por Fábio Cerqueira**
