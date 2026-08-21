# Como identificar e corrigir deadlocks

> Deadlock não é sinal de banco doente: é sinal de **ordem de acesso inconsistente** no
> código. Este documento mostra como recuperar o deadlock que já aconteceu, como ler o
> grafo e como corrigir a causa em vez do sintoma.

| | |
|---|---|
| **Compatibilidade** | SQL Server 2012+ (11.x) · Azure SQL Database: sim |
| **Impacto em produção** | Nenhum — a captura já está ativa por padrão |
| **Permissões** | `VIEW SERVER STATE` |

---

## Problema

A aplicação registra, de forma intermitente:

```text
Transaction (Process ID 73) was deadlocked on lock resources with another process
and has been chosen as the deadlock victim. Rerun the transaction.
```

É o erro **1205**. O SQL Server detectou um ciclo de espera entre duas ou mais transações
e escolheu uma para abortar, porque o ciclo nunca se resolveria sozinho.

Detalhe importante: o SQL Server escolhe como vítima a transação de **rollback mais
barato**, não a culpada. A sessão que aparece no erro geralmente **não** é a que causou o
problema.

## Quando utilizar este roteiro

- Erro 1205 recorrente em log de aplicação.
- Falhas intermitentes que "somem quando repete".
- Aumento de erros em horário de pico sem mudança de volume.

## Quando NÃO utilizar

- **Erro 1222** (`Lock request time out period exceeded`) não é deadlock, é *timeout de
  lock*. O problema é bloqueio longo — vá para
  [`quem-esta-bloqueando-quem.sql`](quem-esta-bloqueando-quem.sql).
- Timeout da aplicação (`CommandTimeout`) também não é deadlock. Veja
  [`../../acesso-a-dados/ado-net/timeout-de-comando-vs-conexao.md`](../../acesso-a-dados/ado-net/timeout-de-comando-vs-conexao.md).
- Deadlock isolado e raro em sistema de alta concorrência pode ser aceitável, desde que a
  aplicação trate com retry. O que não é aceitável é **não saber** que acontece.

---

## Passo 1 — Recuperar o deadlock que já aconteceu

Não é preciso reproduzir nada. A sessão de Extended Events **`system_health`** vem ativa
por padrão desde o SQL Server 2008 e já captura `xml_deadlock_report`.

**Rode:** [`extrair-deadlocks-do-system-health.sql`](extrair-deadlocks-do-system-health.sql)

O alvo em arquivo cobre vários dias; o *ring buffer* cobre bem menos e é circular. Se o
deadlock for antigo e não aparecer, ele já rotacionou — nesse caso, crie uma sessão de
Extended Events dedicada (Passo 5) e aguarde a próxima ocorrência.

> **Não use trace flags 1204/1222 como primeira opção.** Elas escrevem o deadlock no
> ERRORLOG em formato de texto, poluem o log e não trazem nada que a `system_health` já
> não capture em formato estruturado.

## Passo 2 — Ler o grafo

O XML do deadlock tem quatro partes. Leia nesta ordem:

### `<resource-list>` — comece por aqui

Mostra **o que** está em disputa. É a informação mais acionável:

```xml
<keylock hobtid="72057594045595648" dbid="9"
         objectname="Vendas.dbo.Pedido"
         indexname="PK_Pedido" mode="X">
  <owner-list><owner id="process1a2b" mode="X"/></owner-list>
  <waiter-list><waiter id="process3c4d" mode="S" requestType="wait"/></waiter-list>
</keylock>
```

- `objectname` — a tabela;
- `indexname` — **o índice**. Deadlock em índice não clusterizado costuma indicar caminho
  de acesso ruim, não concorrência legítima;
- `mode` — o tipo de lock (`S` compartilhado, `X` exclusivo, `U` de update);
- `keylock` versus `pagelock` versus `objectlock` — a granularidade. `pagelock` sugere que
  o lock escalou de linha para página, o que amplia muito a área de colisão.

### `<process-list>` — quem estava envolvido

Cada `<process>` traz `loginname`, `hostname`, `clientapp`, `isolationlevel`,
`lastbatchstarted` e `transactionname`.

`clientapp` é o que liga o deadlock ao sistema real. Se todos os `clientapp` são
`.Net SqlClient Data Provider`, configure `Application Name` na connection string das
aplicações — sem isso, todo deadlock parece vir do mesmo lugar.

### `<executionStack>` — onde exatamente

```xml
<frame procname="Vendas.dbo.usp_BaixarEstoque" line="42" stmtstart="1180">
```

`procname` e `line` apontam a procedure e a linha. Quando o comando vem da aplicação (SQL
dinâmico ou ORM), o `<inputbuf>` traz o texto enviado.

### `<victim-list>` — quem pagou a conta

Apenas informa qual foi abortada. **Não indica culpa** e raramente é onde está a correção.

## Passo 3 — Identificar o padrão

Quatro padrões cobrem a grande maioria dos deadlocks:

### 1. Ordem de acesso invertida (o mais comum)

```text
Transação A:  UPDATE Pedido    →  UPDATE Estoque
Transação B:  UPDATE Estoque   →  UPDATE Pedido
```

Cada uma segura o que a outra precisa.

**Correção:** padronizar a ordem de acesso às tabelas em todo o código. Se o padrão for
"sempre `Pedido` antes de `Estoque`", o ciclo deixa de ser possível. É a correção mais
barata e mais duradoura, e não custa performance.

### 2. Conversão de lock (`U` → `X`)

Uma transação lê com intenção de atualizar, mantém lock compartilhado e depois tenta
convertê-lo em exclusivo enquanto outra fez o mesmo.

```sql
-- Padrao que provoca conversao
SELECT saldo FROM Conta WHERE id = @id;
-- ... logica ...
UPDATE Conta SET saldo = @novo WHERE id = @id;
```

**Correção:** declarar a intenção já na leitura, dentro da transação:

```sql
SELECT saldo FROM Conta WITH (UPDLOCK, ROWLOCK) WHERE id = @id;
```

`UPDLOCK` adquire diretamente o lock de update, e locks de update são mutuamente
exclusivos entre si — a segunda transação espera em vez de entrar em ciclo. Use com
`ROWLOCK` para evitar escalonamento e mantenha a transação curta.

### 3. Falta de índice

Sem índice adequado, um `UPDATE ... WHERE cliente_id = @x` varre a tabela e bloqueia
linhas que nem deveria tocar. A área de colisão fica muito maior que o necessário.

**Correção:** criar o índice que suporta o predicado. Veja
[`../indexes/encontrar-indices-ausentes.sql`](../indexes/encontrar-indices-ausentes.sql).
Este é o caso em que **um índice elimina deadlocks** — e é mais frequente do que parece.

### 4. Escalonamento de lock

Uma operação que afeta muitas linhas faz o SQL Server escalar locks de linha para tabela.
A partir daí, qualquer concorrente colide.

**Correção:** processar em lotes menores com `COMMIT` frequente. Trocar um `UPDATE` de
2 milhões de linhas por 400 lotes de 5.000 elimina o escalonamento e reduz drasticamente a
janela de bloqueio.

## Passo 4 — Tratar na aplicação (paliativo necessário)

Mesmo com o código correto, deadlock pode ocorrer sob concorrência alta. A aplicação
precisa tratar o erro 1205 com retry — mas **retry é paliativo, não correção**.

```csharp
// Retry apenas para o erro 1205 (deadlock victim).
// Requer: transacao curta e operacao idempotente ou integralmente refeita.
private const int NumeroDeDeadlock = 1205;

public async Task<T> ExecutarComRetryDeDeadlockAsync<T>(
    Func<CancellationToken, Task<T>> operacao,
    int tentativasMaximas = 3,
    CancellationToken cancellationToken = default)
{
    for (var tentativa = 1; ; tentativa++)
    {
        try
        {
            return await operacao(cancellationToken).ConfigureAwait(false);
        }
        catch (SqlException ex) when (ex.Number == NumeroDeDeadlock
                                      && tentativa < tentativasMaximas)
        {
            // Backoff exponencial com jitter: sem o jitter, as duas transacoes
            // que colidiram voltam a colidir no mesmo instante.
            var baseDelay = TimeSpan.FromMilliseconds(100 * Math.Pow(2, tentativa - 1));
            var jitter = TimeSpan.FromMilliseconds(Random.Shared.Next(0, 100));

            await Task.Delay(baseDelay + jitter, cancellationToken).ConfigureAwait(false);
        }
    }
}
```

> O jitter não é detalhe. Sem ele, as duas transações que colidiram esperam exatamente o
> mesmo intervalo e colidem de novo — o retry vira um laço.

Detalhe de plataforma: `Random.Shared` existe a partir do .NET 6. Em .NET Framework, use
uma instância de `Random` compartilhada com proteção adequada, ou
`RandomNumberGenerator`.

## Passo 5 — Monitorar continuamente

Sessão dedicada de Extended Events, com retenção maior que a da `system_health`:

```sql
CREATE EVENT SESSION [captura_deadlocks] ON SERVER
    ADD EVENT sqlserver.xml_deadlock_report
    ADD TARGET package0.event_file
    (
        SET filename    = N'captura_deadlocks.xel',
            max_file_size = 50,        /* MB por arquivo */
            max_rollover_files = 10
    )
    WITH (STARTUP_STATE = ON);
GO

ALTER EVENT SESSION [captura_deadlocks] ON SERVER STATE = START;
GO
```

Ajuste o caminho do `filename` conforme a instância. Com `STARTUP_STATE = ON` a sessão
volta sozinha após restart.

---

## Cuidados

- **Não aumente o `LOCK_TIMEOUT` para "resolver" deadlock.** Não tem efeito: o detector
  age antes, e o ciclo não se resolveria com mais tempo.
- **`WITH (NOLOCK)` não é solução.** Reduz um tipo de colisão e introduz leitura suja,
  duplicada e ausente. Trocar resultado certo por resultado errado não é otimização.
- **`SET DEADLOCK_PRIORITY LOW`** apenas escolhe quem será a vítima. Útil para proteger um
  processo crítico contra um batch, não para eliminar deadlock.
- **`READ_COMMITTED_SNAPSHOT`** elimina a classe de deadlock entre leitura e escrita, mas
  altera o comportamento do banco inteiro e passa a consumir `tempdb` com o version store.
  É decisão de arquitetura, com teste — não ajuste de emergência.

## Performance

A captura de deadlock pela `system_health` tem custo desprezível e já está ligada. Uma
sessão dedicada com alvo em arquivo também tem custo baixo, porque o evento só ocorre no
deadlock. O que custa caro é o trace flag em ERRORLOG de servidor movimentado.

## Segurança

O XML do deadlock contém o texto das instruções, incluindo valores literais quando a
aplicação não parametriza. Trate o arquivo como log de produção: pode conter dado pessoal.

## Referências

- [Analisar e evitar deadlocks](https://learn.microsoft.com/pt-br/sql/relational-databases/sql-server-deadlocks-guide)
- [Sessão system_health](https://learn.microsoft.com/pt-br/sql/relational-databases/extended-events/use-the-system-health-session)
- [Guia de bloqueio e controle de versão de linha](https://learn.microsoft.com/pt-br/sql/relational-databases/sql-server-transaction-locking-and-row-versioning-guide)

---

**Criado por Fábio Cerqueira**
