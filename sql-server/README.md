# SQL Server

> A área mais densa do repositório. Organizada pelo momento em que você precisa de cada
> coisa: durante o incidente, para entender o estado atual, ou para investigar a fundo.

---

## Emergência: comece aqui

**[→ "O SQL Server está lento" — roteiro de diagnóstico](troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md)**

Oito passos que separam bloqueio de query ruim de problema de infraestrutura, com árvore
de decisão e a lista do que **não** fazer sob pressão.

Se você tem trinta segundos: rode
[`diagnostico-rapido-30-segundos.sql`](troubleshooting/diagnostico-rapido-30-segundos.sql)
e **salve a saída em arquivo** antes de tocar em qualquer coisa.

---

## As seis subpastas

| Pasta | Quando usar |
|---|---|
| [`troubleshooting/`](troubleshooting/) | **Durante** um incidente. Bloqueio, deadlock, transaction log, `tempdb`, `KILL` |
| [`monitoramento/`](monitoramento/) | Para saber o que está acontecendo **agora**. Sessões, waits, memória, disco |
| [`performance/`](performance/) | Para investigar **uma query**. Planos, CPU, I/O, estatísticas, parameter sniffing |
| [`indexes/`](indexes/) | Tudo sobre índices: ausentes, não utilizados, duplicados, fragmentação |
| [`espaco-e-crescimento/`](espaco-e-crescimento/) | "Por que o banco está crescendo?" Tamanho de tabelas e índices |
| [`administracao/`](administracao/) | Backup, restore, `DBCC CHECKDB`, permissões, configuração |

---

## Perguntas de produção → arquivo

| A pergunta como ela chega até você | Onde ir |
|---|---|
| "O SQL Server está lento, o que verifico?" | [roteiro de diagnóstico](troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md) |
| "Quem está bloqueando quem?" | [`quem-esta-bloqueando-quem.sql`](troubleshooting/quem-esta-bloqueando-quem.sql) |
| "Qual sessão está na raiz do bloqueio?" | [`arvore-de-bloqueio-hierarquica.sql`](troubleshooting/arvore-de-bloqueio-hierarquica.sql) |
| "Existe transação aberta há muito tempo?" | [`encontrar-transacoes-abertas-longa-duracao.sql`](troubleshooting/encontrar-transacoes-abertas-longa-duracao.sql) |
| "Como identificar deadlocks?" | [`investigar-deadlocks.md`](troubleshooting/investigar-deadlocks.md) |
| "Por que o transaction log está crescendo?" | [`por-que-o-transaction-log-esta-crescendo.md`](troubleshooting/por-que-o-transaction-log-esta-crescendo.md) |
| "Como encontrar problemas no `tempdb`?" | [`diagnosticar-tempdb.md`](troubleshooting/diagnosticar-tempdb.md) |
| "Posso matar essa sessão?" | [`matar-sessao-com-seguranca.md`](troubleshooting/matar-sessao-com-seguranca.md) |
| "Quais queries consomem mais CPU?" | [`queries-que-mais-consomem-cpu.sql`](performance/queries-que-mais-consomem-cpu.sql) |
| "Quais queries fazem mais I/O?" | [`queries-que-mais-fazem-io.sql`](performance/queries-que-mais-fazem-io.sql) |
| "Por que essa query ficou lenta?" | [`queries-mais-lentas-por-duracao.sql`](performance/queries-mais-lentas-por-duracao.sql) |
| "Como leio um plano de execução?" | [`como-ler-um-plano-de-execucao.md`](performance/como-ler-um-plano-de-execucao.md) |
| "O índice existe mas não é usado" | [`sargability-e-indices-ignorados.md`](performance/sargability-e-indices-ignorados.md) |
| "Rápida para um cliente, lenta para outro" | [`parameter-sniffing.md`](performance/parameter-sniffing.md) |
| "Como identificar problemas de estatísticas?" | [`estatisticas-desatualizadas.md`](performance/estatisticas-desatualizadas.md) |
| "Quais índices estão faltando?" | [`encontrar-indices-ausentes.sql`](indexes/encontrar-indices-ausentes.sql) |
| "Quais índices não são utilizados?" | [`encontrar-indices-nao-utilizados.sql`](indexes/encontrar-indices-nao-utilizados.sql) |
| "Quais índices estão duplicados?" | [`encontrar-indices-duplicados-e-redundantes.sql`](indexes/encontrar-indices-duplicados-e-redundantes.sql) |
| "Preciso reconstruir índices?" | [`analisar-fragmentacao.sql`](indexes/analisar-fragmentacao.sql) e [`manutencao-de-indices.md`](indexes/manutencao-de-indices.md) |
| "Qual o tamanho de cada tabela?" | [`tamanho-das-tabelas.sql`](espaco-e-crescimento/tamanho-das-tabelas.sql) |
| "Qual o tamanho de cada índice?" | [`tamanho-dos-indices.sql`](espaco-e-crescimento/tamanho-dos-indices.sql) |
| "Como verificar a saúde do banco?" | [`dbcc-checkdb-integridade.md`](administracao/dbcc-checkdb-integridade.md) |
| "Posso encolher o banco?" | [`shrink-quando-nao-usar.md`](administracao/shrink-quando-nao-usar.md) |
| "Como fazer backup e restore direito?" | [`backup-e-restore.md`](administracao/backup-e-restore.md) |
| "A aplicação conecta como `sa`, e agora?" | [`permissoes-e-menor-privilegio.md`](administracao/permissoes-e-menor-privilegio.md) |

---

## Como os scripts são escritos

Todo `.sql` começa com um cabeçalho que declara objetivo, **compatibilidade de versão**,
**impacto em produção**, permissões necessárias, tempo estimado e limitações conhecidas.
O cabeçalho existe para ser lido antes da execução — principalmente às três da manhã.

Todo script termina com um bloco **"COMO LER O RESULTADO"**, que explica o que cada coluna
significa e, mais importante, **o que fazer com ela**.

Os scripts de diagnóstico são somente leitura. Os comandos que alteram estado vêm
comentados por padrão, precedidos de um bloco de aviso.

---

## Compatibilidade

O piso da maioria dos scripts é **SQL Server 2012 (11.x)**. Quando algo exige versão
superior, o cabeçalho diz qual e, quando possível, oferece alternativa.

Pontos de corte que aparecem com frequência:

| Recurso | Versão mínima |
|---|---|
| `open_transaction_count` em `sys.dm_exec_sessions` | 2012 (11.x) |
| `sys.dm_db_stats_properties` | 2012 SP1 (2008 R2 SP2 também) |
| **Query Store** | 2016 (13.x) |
| Colunas de *memory grant* em `sys.dm_exec_query_stats` | 2016 (13.x) |
| Limiar dinâmico de atualização de estatísticas por padrão | 2016 (13.x), nível de compatibilidade 130+ |
| *Scalar UDF Inlining* | 2019 (15.x) |
| *Parameter Sensitive Plan optimization* | 2022 (16.x) |

---

## Uma advertência que vale para tudo aqui

As DMVs de estatística acumulada — `sys.dm_os_wait_stats`, `sys.dm_exec_query_stats`,
`sys.dm_db_index_usage_stats`, `sys.dm_db_missing_index_*` — **zeram no restart da
instância**. Cada script mostra o uptime justamente por isso.

Nunca decida remover um índice, nem conclua nada sobre waits, com uptime menor que um
**ciclo completo de negócio** da sua empresa. O índice que parece inútil em duas semanas
pode ser o que sustenta o fechamento anual.

---

**Criado por Fábio Cerqueira**
