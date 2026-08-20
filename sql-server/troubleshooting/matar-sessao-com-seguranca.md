# Matar uma sessão com segurança (`KILL`)

> `KILL` é o botão vermelho do SQL Server. Funciona, resolve o minuto seguinte e pode
> transformar um incidente de lentidão em um incidente de indisponibilidade. Este
> documento é a lista de verificações antes de apertá-lo.

| | |
|---|---|
| **Compatibilidade** | SQL Server 2012+ (11.x) · Azure SQL Database: sim |
| **Impacto em produção** | **Alto.** Provoca rollback e perda do trabalho em andamento |
| **Permissões** | `ALTER ANY CONNECTION`, ou `processadmin`/`sysadmin` |
| **Reversível** | **Não.** Não existe "desmatar" uma sessão |

---

## Problema

Uma sessão está bloqueando o sistema inteiro. A pressão para "matar isso agora" é enorme.
O risco é que `KILL` na sessão errada, ou na hora errada, piore tudo:

- matar uma **vítima intermediária** não resolve nada — a raiz continua bloqueando;
- matar uma transação que já modificou muitos dados dispara um **rollback** que pode
  demorar mais do que o bloqueio original, e **durante o rollback os locks continuam
  retidos**;
- matar sem registrar evidência elimina a possibilidade de descobrir a causa, garantindo
  que o problema volte.

## Quando utilizar

- A sessão está **dormindo** (`status = 'sleeping'`) com transação aberta e abandonada,
  bloqueando outras — o caso mais seguro, porque não há trabalho em curso a desfazer.
- A sessão é a **raiz** confirmada de uma cadeia de bloqueio e o prejuízo por minuto
  justifica a interrupção.
- É uma consulta de leitura (relatório, `SELECT` pesado) que virou um problema. Rollback
  de leitura é barato.

## Quando NÃO utilizar

- **Quando a transação já está em rollback.** Se `estado_transacao` indica rollback em
  andamento, matar de novo não acelera nada e reiniciar a instância é pior: o SQL Server
  refaz o mesmo trabalho na recuperação do banco, com o banco indisponível.
- **Quando a sessão está executando `BACKUP`, `RESTORE` ou `DBCC CHECKDB`.** Interromper
  um `RESTORE` deixa o banco em estado de recuperação e o incidente muda de categoria.
- **Quando é uma vítima intermediária**, e não a raiz da cadeia.
- **Quando você ainda não salvou a evidência.**
- **Quando o rollback estimado é maior que o tempo restante de bloqueio.** Uma carga que
  já gravou 20 milhões de linhas há 40 minutos vai levar um tempo comparável para
  desfazer — e segurando os locks o tempo todo.
- **Como rotina.** Job que mata sessões automaticamente esconde o defeito da aplicação e
  cria um problema pior: perda silenciosa de trabalho.

---

## Procedimento

### Passo 1 — Confirme que é a raiz

```sql
-- arvore-de-bloqueio-hierarquica.sql
-- A linha marcada como "*** RAIZ ***" é a única candidata.
```

Se você não rodou a árvore, você não sabe se é a raiz. Não mate.

### Passo 2 — Salve a evidência

Grave em arquivo, com horário:

- saída de [`quem-esta-bloqueando-quem.sql`](quem-esta-bloqueando-quem.sql);
- saída de [`arvore-de-bloqueio-hierarquica.sql`](arvore-de-bloqueio-hierarquica.sql);
- `session_id`, `login_name`, `host_name`, `program_name` e o texto completo do comando.

O `program_name` é o que permite descobrir **qual aplicação** abriu a transação
defeituosa. Perdido isso, a correção definitiva fica sem endereço.

### Passo 3 — Avalie o custo do rollback

```sql
/* Quanto trabalho esta sessao ja fez e vai precisar desfazer */
SELECT
    s.session_id,
    idade_minutos    = DATEDIFF(MINUTE, tat.transaction_begin_time, SYSDATETIME()),
    log_usado_mb     = dbt.database_transaction_log_bytes_used / 1024.0 / 1024.0,
    registros_de_log = dbt.database_transaction_log_record_count,
    s.status,
    s.program_name
FROM sys.dm_tran_active_transactions AS tat
INNER JOIN sys.dm_tran_session_transactions AS tst
        ON tst.transaction_id = tat.transaction_id
INNER JOIN sys.dm_exec_sessions AS s
        ON s.session_id = tst.session_id
LEFT JOIN sys.dm_tran_database_transactions AS dbt
       ON dbt.transaction_id = tat.transaction_id
WHERE s.session_id = <SPID>;
```

Regra prática de leitura:

| `log_usado_mb` | Interpretação |
|---|---|
| Próximo de zero | Transação aberta que não gravou nada. Rollback instantâneo. **Seguro** |
| Dezenas de MB | Rollback de segundos a poucos minutos |
| Centenas de MB ou mais | Rollback longo, com locks retidos o tempo todo. **Reavalie** |

Uma sessão `sleeping` com `log_usado_mb` perto de zero é o cenário ideal: ela não fez
nada, só esqueceu de fechar a transação.

### Passo 4 — Execute

```sql
KILL <SPID>;
```

### Passo 5 — Acompanhe o rollback

```sql
-- Esta forma do comando NAO mata nada: apenas consulta o progresso do rollback.
KILL <SPID> WITH STATUSONLY;
```

A saída informa o percentual concluído e a estimativa restante. Se o percentual não
avança, **não mate de novo e não reinicie a instância** — aguarde. Reiniciar transfere o
mesmo rollback para a fase de recuperação do banco, agora com o banco inacessível.

> `KILL ... WITH STATUSONLY` só retorna progresso para sessões em rollback. Para uma
> sessão que não está revertendo nada, a mensagem indica que não há status a exibir.

---

## Alternativas antes do `KILL`

| Situação | Alternativa |
|---|---|
| Bloqueio causado por relatório pesado | Rodar o relatório em réplica de leitura, ou fora do horário |
| Bloqueio recorrente de leitura contra escrita | Avaliar `READ_COMMITTED_SNAPSHOT` — muda o comportamento do banco inteiro, exige teste |
| Aplicação abandona transações | Corrigir `using`/`Dispose`, reduzir escopo da transação, nunca chamar serviço externo dentro dela |
| Job de carga bloqueia o dia | Reprogramar janela, processar em lotes menores com `COMMIT` frequente |

Processar em lotes menores é a alternativa mais subestimada: uma carga que faz `COMMIT` a
cada 5.000 linhas bloqueia por milissegundos de cada vez, em vez de segurar locks por
quarenta minutos.

---

## Cuidados

- `KILL` aceita também um **UOW** (identificador de transação distribuída) para transações
  do MS DTC órfãs — sintaxe diferente e caso específico.
- Matar a sessão de um **job do SQL Agent** faz o job falhar; verifique se há tratamento
  e alerta configurados.
- Em ambientes com Availability Groups, um rollback grande gera volume de log a replicar
  e pode atrasar as secundárias.

## Segurança

`ALTER ANY CONNECTION` é uma permissão de instância que permite derrubar **qualquer**
sessão. Não conceda de forma ampla; prefira conceder a um papel específico de operação e
registre quem tem.

## Troubleshooting

| Sintoma | Causa provável | Ação |
|---|---|---|
| `KILL` executa mas a sessão continua | Rollback em andamento | Acompanhe com `WITH STATUSONLY` e aguarde |
| Rollback parado em uma porcentagem | Rollback de operação muito grande, ou espera por recurso externo | Aguarde. Não reinicie |
| `Cannot use KILL to kill your own process.` | Você passou o próprio `@@SPID` | Confira o número |
| `Only user processes can be killed.` | Tentativa de matar sessão de sistema | Não é permitido, e não é o problema |

## Referências

- [`KILL` (Transact-SQL)](https://learn.microsoft.com/pt-br/sql/t-sql/language-elements/kill-transact-sql)
- [Entender e resolver problemas de bloqueio](https://learn.microsoft.com/pt-br/troubleshoot/sql/database-engine/performance/understand-resolve-blocking)

---

**Criado por Fábio Cerqueira**
