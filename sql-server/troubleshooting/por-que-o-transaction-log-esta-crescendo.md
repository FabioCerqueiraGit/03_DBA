# "O transaction log está crescendo e vai encher o disco"

> Em quase todos os casos a resposta está em uma única coluna:
> `sys.databases.log_reuse_wait_desc`. Este documento mostra como lê-la, o que fazer em
> cada caso e por que a "solução rápida" que circula na internet costuma destruir a
> estratégia de backup.

| | |
|---|---|
| **Sintoma** | Arquivo `.ldf` crescendo sem parar; erro 9002 (`transaction log for database is full`) |
| **Compatibilidade** | SQL Server 2012+ (11.x) |
| **Impacto do diagnóstico** | Nenhum — somente leitura |
| **Permissões** | `VIEW SERVER STATE`, `VIEW ANY DEFINITION` |

---

## Problema

O arquivo de log cresce continuamente. Ou o disco está acabando, ou a aplicação já parou
com o erro 9002.

O ponto que gera mais confusão: **o transaction log não é lixo acumulado.** Ele é um
arquivo circular. O SQL Server reutiliza o espaço interno assim que pode — e quando não
pode, é porque algo específico o impede. Descobrir esse "algo" é todo o trabalho.

## Passo 1 — Perguntar ao próprio SQL Server

```sql
SELECT
    banco               = name,
    recovery_model_desc,
    log_reuse_wait_desc
FROM sys.databases
WHERE database_id > 4;
```

Para o diagnóstico completo, com tamanhos, transações abertas e histórico de backup:
[`diagnosticar-crescimento-transaction-log.sql`](diagnosticar-crescimento-transaction-log.sql)

## Passo 2 — Interpretar

| `log_reuse_wait_desc` | Causa | Correção correta |
|---|---|---|
| `NOTHING` | Nada impede a reutilização | O log não deveria estar crescendo. Investigue crescimento pontual (carga, `REBUILD` de índice) |
| `LOG_BACKUP` | Banco em `FULL`/`BULK_LOGGED` sem backup de log em dia | **Fazer backup de log.** Criar ou corrigir o job |
| `ACTIVE_TRANSACTION` | Transação aberta há muito tempo | Encontrar e encerrar a transação: [`encontrar-transacoes-abertas-longa-duracao.sql`](encontrar-transacoes-abertas-longa-duracao.sql) |
| `ACTIVE_BACKUP_OR_RESTORE` | Backup ou restore em andamento | Aguardar |
| `REPLICATION` | Replicação ou CDC não consumiu o log | Verificar o Log Reader Agent. Atenção: CDC mantém este estado mesmo após remover a replicação, se não foi desabilitado corretamente |
| `AVAILABILITY_REPLICA` | Réplica secundária atrasada ou fora do ar | Restabelecer a réplica |
| `DATABASE_MIRRORING` | Mirroring suspenso ou atrasado | Retomar o mirroring |
| `CHECKPOINT` / `LOG_SCAN` | Transitórios | Normalmente se resolvem sozinhos |
| `XTP_CHECKPOINT` | Checkpoint de In-Memory OLTP pendente | Verificar o filegroup memory-optimized |

### O caso mais comum: `LOG_BACKUP`

O banco está em recovery model `FULL` — que é o correto para um sistema que precisa de
restore point-in-time — mas ninguém faz backup de log. O SQL Server então **não pode**
truncar: ele está guardando tudo, exatamente como você mandou.

```sql
BACKUP LOG [<BANCO>]
TO DISK = N'<CAMINHO>\<BANCO>_log_<AAAAMMDD_HHMM>.trn'
WITH COMPRESSION, CHECKSUM, STATS = 10;
```

Depois do backup, o espaço interno é liberado para reutilização. **O arquivo continua do
mesmo tamanho** — e isso é normal e desejável. Espaço interno livre é o que evita novos
eventos de autogrow.

A correção definitiva é o **job periódico** de backup de log, com intervalo alinhado ao
RPO acordado. Se o negócio aceita perder no máximo 15 minutos, o backup de log é de 15 em
15 minutos.

### O caso mais mal resolvido: `ACTIVE_TRANSACTION`

Nenhum backup de log vai truncar enquanto a transação estiver aberta — o log a partir do
início dela é necessário para um eventual rollback. Fazer backup de log em laço não
adianta e ainda enche o disco de arquivos `.trn`.

A correção é na **aplicação**. Veja o Passo 3 de
[`sql-server-esta-lento-roteiro-de-diagnostico.md`](sql-server-esta-lento-roteiro-de-diagnostico.md).

---

## O que NÃO fazer

### Trocar o recovery model para `SIMPLE`

É o conselho mais repetido e o mais perigoso.

```sql
-- ❌ NAO faca isso sem entender a consequencia
ALTER DATABASE [<BANCO>] SET RECOVERY SIMPLE;
```

O que acontece de fato:

- o log passa a ser truncado automaticamente no checkpoint — o sintoma some;
- **a cadeia de backup é quebrada**;
- **você perde a capacidade de restore point-in-time**;
- a partir daí, o máximo que se recupera é o último backup full ou diferencial.

Se o banco estava em `FULL`, era porque alguém decidiu que perder horas de transação era
inaceitável. Mudar para `SIMPLE` no meio de um incidente reverte essa decisão em silêncio,
e ninguém percebe até o dia em que for preciso restaurar.

`SIMPLE` é legítimo — para banco de desenvolvimento, staging, data warehouse recarregável
ou qualquer base em que perder tudo desde o último full seja aceitável. É uma **decisão de
negócio documentada**, não um atalho de madrugada.

Se precisar mesmo mudar, faça na ordem certa e registre:

1. confirme com o responsável que o RPO permite;
2. mude o recovery model;
3. **faça um backup full imediatamente** — a cadeia anterior já não vale;
4. documente a mudança e a data.

### Encolher o log como rotina

```sql
-- ❌ Nao resolve a causa
DBCC SHRINKFILE (N'<ARQUIVO_LOG>', 0);
```

Encolher o log não impede o crescimento — o log volta a crescer, agora com autogrow no
meio do expediente, e cada crescimento gera VLFs novos. Um log com milhares de VLFs deixa
o *crash recovery* e o backup de log mais lentos.

Encolher é aceitável **uma vez**, depois de corrigida a causa, quando o arquivo cresceu de
forma anômala e não voltará a precisar daquele tamanho. Veja
[`../administracao/shrink-quando-nao-usar.md`](../administracao/shrink-quando-nao-usar.md).

### `BACKUP LOG ... WITH TRUNCATE_ONLY`

Não existe mais. Foi removido a partir do SQL Server 2008. Instruções que ainda circulam
recomendando isso são de 2005 — e mesmo lá quebravam a cadeia de backup.

---

## Prevenção

| Medida | Por quê |
|---|---|
| Backup de log com intervalo alinhado ao RPO | Única forma correta de manter o log sob controle em `FULL` |
| Autogrow em **MB fixo**, nunca em percentual | Percentual faz cada crescimento ser maior que o anterior, de forma acelerada |
| Incremento razoável (por exemplo 512 MB ou 1 GB em bases grandes) | Incrementos pequenos geram muitos eventos de autogrow e muitos VLFs |
| Dimensionar o log de antemão | Se a maior operação do mês gera 8 GB de log, o log tem de nascer com folga sobre isso |
| Habilitar *Instant File Initialization* | Acelera o crescimento de arquivos de **dados**. **Não se aplica ao log**, que sempre precisa ser zerado |
| Monitorar `log_reuse_wait_desc` | Alerta antes de o disco encher |
| Processar cargas grandes em lotes com `COMMIT` | Uma transação única de milhões de linhas segura o log inteiro |

---

## Troubleshooting

| Erro | Significado | Ação |
|---|---|---|
| `9002 — The transaction log for database '<x>' is full due to '<motivo>'` | O motivo vem na própria mensagem | Trate conforme a tabela do Passo 2 |
| Log cresce mesmo com backup de log rodando | Provavelmente `ACTIVE_TRANSACTION` | Passo 2, linha correspondente |
| `log_reuse_wait_desc = 'REPLICATION'` sem replicação configurada | CDC habilitado, ou replicação removida de forma incompleta | Verificar `sys.databases.is_cdc_enabled` e limpar os artefatos remanescentes |
| Disco cheio e o banco parou | Emergência | Liberar espaço no volume, fazer backup de log, e só então tratar a causa |

## Referências

- [Guia de arquitetura e gerenciamento do log de transações](https://learn.microsoft.com/pt-br/sql/relational-databases/sql-server-transaction-log-architecture-and-management-guide)
- [Solucionar problemas de log de transações cheio (erro 9002)](https://learn.microsoft.com/pt-br/sql/relational-databases/logs/troubleshoot-a-full-transaction-log-sql-server-error-9002)
- [`sys.databases`](https://learn.microsoft.com/pt-br/sql/relational-databases/system-catalog-views/sys-databases-transact-sql)

---

**Criado por Fábio Cerqueira**
