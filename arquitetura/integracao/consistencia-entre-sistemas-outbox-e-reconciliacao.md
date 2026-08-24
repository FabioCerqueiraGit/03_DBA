# Consistência entre sistemas — outbox, idempotência e reconciliação

> O pedido foi gravado mas o parceiro não recebeu. Ou recebeu duas vezes. Ou recebeu e o `commit`
> local falhou. O problema tem nome e tem solução conhecida.

| | |
|---|---|
| **Compatibilidade** | SQL Server 2008+ para o outbox; `OUTPUT` com `READPAST` a partir do 2005. Código em .NET Framework 4.5+ ou .NET 6+. |
| **Impacto** | **Alto.** Altera esquema e o fluxo de gravação. |

---

## O problema da escrita dupla

```csharp
// PARECE correto. Nao e.
await _contexto.SaveChangesAsync(ct);              // 1. grava no banco
await _clienteHttp.NotificarParceiroAsync(pedido); // 2. avisa o parceiro
```

Os dois passos não compartilham transação. Quatro finais possíveis:

| Passo 1 | Passo 2 | Resultado |
|---|---|---|
| OK | OK | Correto |
| Falha | — | Correto (nada aconteceu) |
| OK | **Falha** | **Pedido existe aqui e não lá** |
| OK | Timeout, mas o parceiro processou | **Retentativa duplica o pedido lá** |

Inverter a ordem não resolve — só troca qual lado fica órfão.

### Por que não transação distribuída

O MSDTC resolve isso entre dois SQL Servers, mas: não funciona com HTTP, exige configuração de
infraestrutura e firewall, mantém bloqueio nos dois lados durante toda a operação e transforma
qualquer lentidão do parceiro em bloqueio no seu banco. Em integração com terceiros, não é uma
opção.

---

## Solução — Transactional Outbox

A ideia: **a intenção de notificar é gravada na mesma transação do dado**. Como as duas escritas
vão para o mesmo banco, a atômicidade é do SQL Server. Um processo separado lê a tabela e entrega.

### A tabela

```sql
CREATE TABLE dbo.Outbox
(
    Id               BIGINT IDENTITY(1,1) NOT NULL,
    TipoEvento       VARCHAR(100)   NOT NULL,
    ChaveAgregado    VARCHAR(100)   NOT NULL,   -- ex.: numero do pedido
    Payload          NVARCHAR(MAX)  NOT NULL,
    CorrelationId    VARCHAR(64)    NULL,
    CriadoEm         DATETIME2(3)   NOT NULL
                     CONSTRAINT DF_Outbox_CriadoEm DEFAULT (SYSUTCDATETIME()),
    Status           VARCHAR(20)    NOT NULL
                     CONSTRAINT DF_Outbox_Status DEFAULT ('Pendente'),
    Tentativas       INT            NOT NULL
                     CONSTRAINT DF_Outbox_Tentativas DEFAULT (0),
    ProximaTentativa DATETIME2(3)   NULL,
    ProcessandoDesde DATETIME2(3)   NULL,
    UltimoErro       NVARCHAR(2000) NULL,
    EnviadoEm        DATETIME2(3)   NULL,
    CONSTRAINT PK_Outbox PRIMARY KEY CLUSTERED (Id)
);

-- Indice filtrado: so as linhas pendentes entram nele.
-- Em outbox com milhoes de linhas historicas, isso e a diferenca entre
-- um seek de milissegundos e uma varredura.
CREATE NONCLUSTERED INDEX IX_Outbox_Pendentes
    ON dbo.Outbox (ProximaTentativa, Id)
    INCLUDE (TipoEvento, Payload, CorrelationId)
    WHERE Status = 'Pendente';
```

### A gravação

```csharp
await using var transacao = await _contexto.Database.BeginTransactionAsync(ct);

_contexto.Pedidos.Add(pedido);

_contexto.Outbox.Add(new MensagemOutbox
{
    TipoEvento    = "PedidoCriado",
    ChaveAgregado = pedido.Numero,
    Payload       = JsonSerializer.Serialize(new { pedido.Numero, pedido.Total }),
    CorrelationId = _contextoDeCorrelacao.Id
});

// Uma transacao, um commit. Ou os dois existem, ou nenhum.
await _contexto.SaveChangesAsync(ct);
await transacao.CommitAsync(ct);
```

A partir daqui, o caso "pedido existe e ninguém foi avisado" deixa de ser possível: se o pedido
foi gravado, a mensagem também foi.

### O despachante

```sql
-- Reivindicacao atomica. READPAST permite varias instancias
-- sem que uma espere pelo lote da outra.
UPDATE TOP (50) o
   SET o.Status           = 'Processando',
       o.ProcessandoDesde = SYSUTCDATETIME()
  OUTPUT inserted.Id, inserted.TipoEvento, inserted.Payload, inserted.CorrelationId
  FROM dbo.Outbox AS o WITH (READPAST, UPDLOCK, ROWLOCK)
 WHERE o.Status = 'Pendente'
   AND (o.ProximaTentativa IS NULL OR o.ProximaTentativa <= SYSUTCDATETIME());
```

O laço roda em um `BackgroundService` — com todos os cuidados descritos em
[`dotnet/background-services/`](../../dotnet/background-services/servico-em-segundo-plano-sem-derrubar-a-aplicacao.md).
Em caso de falha, `Tentativas` é incrementado e `ProximaTentativa` recebe um recuo exponencial;
após N tentativas, `Status` vira `Falha` e a linha sai do fluxo automático.

**Recuperação de itens presos** — se o processo morre entre reivindicar e entregar:

```sql
UPDATE dbo.Outbox
   SET Status = 'Pendente', ProcessandoDesde = NULL
 WHERE Status = 'Processando'
   AND ProcessandoDesde < DATEADD(MINUTE, -15, SYSUTCDATETIME());
```

---

## O que o outbox NÃO resolve: a duplicidade

O outbox garante **pelo menos uma entrega**. Ele não garante exatamente uma — se a entrega chega
ao parceiro e a resposta se perde, a retentativa envia de novo.

> **"Exactly-once" não existe em sistemas distribuídos.** O que existe é entrega ao menos uma vez
> somada a **processamento idempotente** no destino. Essa combinação produz o efeito prático que se
> deseja.

### Do lado de quem envia

Mande uma chave de idempotência estável — a mesma em toda retentativa da mesma mensagem:

```csharp
requisicao.Headers.TryAddWithoutValidation(
    "Idempotency-Key", $"{mensagem.TipoEvento}:{mensagem.ChaveAgregado}");
```

O erro comum é gerar um `Guid.NewGuid()` a cada tentativa — o que faz o parceiro tratar cada
retentativa como operação nova.

### Do lado de quem recebe — tabela de entrada

```sql
CREATE TABLE dbo.MensagemRecebida
(
    ChaveIdempotencia VARCHAR(200)  NOT NULL,
    RecebidoEm        DATETIME2(3)  NOT NULL
                      CONSTRAINT DF_MensagemRecebida_RecebidoEm DEFAULT (SYSUTCDATETIME()),
    RespostaGravada   NVARCHAR(MAX) NULL,
    CONSTRAINT PK_MensagemRecebida PRIMARY KEY CLUSTERED (ChaveIdempotencia)
);
```

A chave primária é o mecanismo: o segundo `INSERT` da mesma chave falha com violação de
restrição (erro 2627), e aí devolve-se a resposta já gravada.

```csharp
try
{
    await using var transacao = await contexto.Database.BeginTransactionAsync(ct);

    contexto.MensagensRecebidas.Add(new MensagemRecebida
    {
        ChaveIdempotencia = chave,
        RespostaGravada   = JsonSerializer.Serialize(resultado)
    });

    await ProcessarAsync(mensagem, ct);   // efeito de negocio
    await contexto.SaveChangesAsync(ct);  // marca e efeito, na MESMA transacao
    await transacao.CommitAsync(ct);

    return resultado;
}
catch (DbUpdateException excecao)
    when (excecao.InnerException is SqlException { Number: 2627 or 2601 })
{
    // Duplicata. Nao e erro: devolve o resultado do processamento original.
    _logger.LogInformation(
        "Mensagem ja processada. Chave={Chave}", chave);

    return await ObterRespostaGravadaAsync(chave, ct);
}
```

O ponto essencial: **a marca de idempotência e o efeito de negócio na mesma transação**. Marcar
antes, fora da transação, cria a janela em que a mensagem consta como processada mas o efeito não
ocorreu.

---

## Quando não dá para desfazer: compensação

Algumas operações atravessam sistemas e não cabem em uma transação: reservar estoque, cobrar,
emitir nota. Se a emissão falha, não há `ROLLBACK` que estorne a cobrança.

A saída é a **compensação**: para cada passo, uma operação inversa explícita.

| Passo | Compensação |
|---|---|
| Reservar estoque | Liberar reserva |
| Cobrar | Estornar |
| Emitir nota | Cancelar nota |

Três cuidados que definem se isso funciona:

1. **A compensação também falha.** Ela precisa de retentativa, e o estado "aguardando compensação"
   precisa ser visível a quem opera o sistema.
2. **Nem tudo é compensável.** E-mail enviado não volta. Ordene os passos para que o irreversível
   seja o último.
3. **O estado intermediário é visível.** Diferente de uma transação, aqui existe um instante em que
   o estoque está reservado e a cobrança ainda não ocorreu. O negócio precisa aceitar isso — e a
   interface precisa representá-lo.

---

## Reconciliação — o que nenhum padrão dispensa

Outbox, idempotência e compensação reduzem a divergência. Nenhum a elimina: bug, intervenção
manual e falha do parceiro continuam existindo.

**Toda integração relevante precisa de uma rotina que compare os dois lados periodicamente.**

```sql
-- Divergencias entre o que registramos e o que o parceiro confirmou.
-- FULL OUTER JOIN pega os dois sentidos: o que falta la e o que sobra la.
SELECT
    COALESCE(local.Numero, parceiro.Numero)  AS numero_pedido,
    local.Total                              AS total_local,
    parceiro.Total                           AS total_parceiro,
    CASE WHEN parceiro.Numero IS NULL THEN 'Ausente no parceiro'
         WHEN local.Numero    IS NULL THEN 'Ausente aqui'
         WHEN local.Total <> parceiro.Total THEN 'Valor divergente'
    END                                      AS tipo_divergencia
FROM      dbo.Pedido            AS local
FULL JOIN staging.PedidoParceiro AS parceiro ON parceiro.Numero = local.Numero
WHERE local.CriadoEm >= DATEADD(DAY, -7, SYSUTCDATETIME())
   OR parceiro.CriadoEm >= DATEADD(DAY, -7, SYSUTCDATETIME())
HAVING COUNT(*) > 0;
```

Duas regras operacionais que fazem a reconciliação valer alguma coisa:

- **Registre a execução mesmo quando não há divergência.** Sem isso, não se distingue "está tudo
  certo" de "a rotina parou de rodar há três semanas".
- **Divergência gera alerta para uma pessoa**, não apenas uma linha em log. Relatório que ninguém
  lê é equivalente a não ter reconciliação.

---

## Quando NÃO usar outbox

| Situação | Alternativa |
|---|---|
| A operação é síncrona por natureza e o usuário espera a resposta | Chamada direta com retentativa e circuit breaker — ver [`api-integracao/resiliencia/`](../../api-integracao/resiliencia/) |
| Não há escrita local para amarrar à mensagem | Não há escrita dupla; o problema é outro |
| O volume justifica uma fila real (Service Bus, RabbitMQ) | Use a fila. O outbox continua útil **antes** dela, para publicar de forma confiável |
| Perder a mensagem é aceitável | Não adicione a complexidade |

> Outbox e fila não competem. A fila resolve entrega e escala; o outbox resolve a atômicidade entre
> gravar no banco e publicar na fila — que é exatamente a mesma escrita dupla do início.

---

## Checklist

- [ ] Nenhuma chamada HTTP dentro de transação de banco aberta.
- [ ] Mensagem gravada na **mesma transação** do dado que a origina.
- [ ] Índice filtrado sobre as linhas pendentes do outbox.
- [ ] Despachante com reivindicação atômica e recuperação de itens presos.
- [ ] Recuo exponencial e limite de tentativas, com estado terminal visível.
- [ ] Chave de idempotência **estável** entre retentativas.
- [ ] Consumidor idempotente, com a marca gravada na mesma transação do efeito.
- [ ] Compensação definida para cada passo reversível; irreversíveis por último.
- [ ] Rotina de reconciliação periódica, que registra execução mesmo sem divergência.
- [ ] Divergência gera alerta acionável.
- [ ] Correlation ID propagado da origem até o parceiro — ver [`dotnet/logging/`](../../dotnet/logging/).
- [ ] Política de expurgo do outbox definida (a tabela cresce indefinidamente sem ela).

---

## Referências

- [Microsoft Learn — Transactional Outbox pattern](https://learn.microsoft.com/azure/architecture/best-practices/transactional-outbox-cosmos)
- [Microsoft Learn — Idempotent message processing](https://learn.microsoft.com/azure/architecture/reference-architectures/containers/aks-mission-critical/mission-critical-data-platform)
- [Microsoft Learn — Saga distributed transactions pattern](https://learn.microsoft.com/azure/architecture/reference-architectures/saga/saga)
- [Microsoft Learn — Compensating Transaction pattern](https://learn.microsoft.com/azure/architecture/patterns/compensating-transaction)
- [Microsoft Learn — Table hints (`READPAST`, `UPDLOCK`)](https://learn.microsoft.com/sql/t-sql/queries/hints-transact-sql-table)

---

**Criado por Fábio Cerqueira**
