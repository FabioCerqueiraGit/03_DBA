# Índice por tecnologia

> **Quero ver o que existe sobre...** Inventário completo do repositório, organizado por
> tecnologia.
>
> Navegação: **Tecnologia → Problema → Solução**

Se você sabe o sintoma mas não a causa, use
[`INDICE-POR-SINTOMA.md`](INDICE-POR-SINTOMA.md).

---

## SQL Server

### Troubleshooting — durante o incidente

| Arquivo | Responde a |
|---|---|
| [`sql-server-esta-lento-roteiro-de-diagnostico.md`](sql-server/troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md) | **Documento âncora.** 8 passos, árvore de decisão, o que não fazer |
| [`diagnostico-rapido-30-segundos.sql`](sql-server/troubleshooting/diagnostico-rapido-30-segundos.sql) | Triagem geral em uma execução |
| [`quem-esta-bloqueando-quem.sql`](sql-server/troubleshooting/quem-esta-bloqueando-quem.sql) | Pares bloqueador/bloqueado com o texto da query |
| [`arvore-de-bloqueio-hierarquica.sql`](sql-server/troubleshooting/arvore-de-bloqueio-hierarquica.sql) | A sessão RAIZ da cadeia |
| [`encontrar-transacoes-abertas-longa-duracao.sql`](sql-server/troubleshooting/encontrar-transacoes-abertas-longa-duracao.sql) | Transação antiga e log retido |
| [`extrair-deadlocks-do-system-health.sql`](sql-server/troubleshooting/extrair-deadlocks-do-system-health.sql) | Deadlocks já capturados pela instância |
| [`investigar-deadlocks.md`](sql-server/troubleshooting/investigar-deadlocks.md) | Ler o grafo, achar o padrão, corrigir |
| [`por-que-o-transaction-log-esta-crescendo.md`](sql-server/troubleshooting/por-que-o-transaction-log-esta-crescendo.md) | `log_reuse_wait_desc` e o perigo de mudar para `SIMPLE` |
| [`diagnosticar-crescimento-transaction-log.sql`](sql-server/troubleshooting/diagnosticar-crescimento-transaction-log.sql) | Diagnóstico completo do log |
| [`diagnosticar-tempdb.md`](sql-server/troubleshooting/diagnosticar-tempdb.md) | Os três consumidores e a contenção de alocação |
| [`analisar-uso-do-tempdb.sql`](sql-server/troubleshooting/analisar-uso-do-tempdb.sql) | Quem consome o `tempdb` |
| [`matar-sessao-com-seguranca.md`](sql-server/troubleshooting/matar-sessao-com-seguranca.md) | Checklist antes de `KILL`, e quando não matar |

### Monitoramento — o que acontece agora

| Arquivo | Responde a |
|---|---|
| [`sessoes-e-requests-em-execucao.sql`](sql-server/monitoramento/sessoes-e-requests-em-execucao.sql) | Quem está conectado e o que está rodando |
| [`waits-em-tempo-real.sql`](sql-server/monitoramento/waits-em-tempo-real.sql) | O que está esperando **agora** |
| [`analisar-waits-acumulados.sql`](sql-server/monitoramento/analisar-waits-acumulados.sql) | Onde a instância gasta tempo esperando |
| [`memory-grants-e-fila-de-memoria.sql`](sql-server/monitoramento/memory-grants-e-fila-de-memoria.sql) | Fila por memória e desperdício de concessão |
| [`espaco-em-disco-e-arquivos-do-banco.sql`](sql-server/monitoramento/espaco-em-disco-e-arquivos-do-banco.sql) | Espaço e latência real de I/O |

### Performance — investigar uma query

| Arquivo | Responde a |
|---|---|
| [`queries-que-mais-consomem-cpu.sql`](sql-server/performance/queries-que-mais-consomem-cpu.sql) | Top CPU, e falta de parametrização |
| [`queries-que-mais-fazem-io.sql`](sql-server/performance/queries-que-mais-fazem-io.sql) | Top I/O, e quem lê muito para devolver pouco |
| [`queries-mais-lentas-por-duracao.sql`](sql-server/performance/queries-mais-lentas-por-duracao.sql) | Duração, Query Store e regressão de plano |
| [`como-ler-um-plano-de-execucao.md`](sql-server/performance/como-ler-um-plano-de-execucao.md) | Roteiro de leitura em 5 passos |
| [`estatisticas-desatualizadas.md`](sql-server/performance/estatisticas-desatualizadas.md) | A causa nº 1 de "ficou lento do nada" |
| [`verificar-estatisticas-desatualizadas.sql`](sql-server/performance/verificar-estatisticas-desatualizadas.sql) | Quais estatísticas estão obsoletas |
| [`parameter-sniffing.md`](sql-server/performance/parameter-sniffing.md) | Rápida para um parâmetro, lenta para outro |
| [`sargability-e-indices-ignorados.md`](sql-server/performance/sargability-e-indices-ignorados.md) | Os seis padrões que matam o índice |

### Índices

| Arquivo | Responde a |
|---|---|
| [`encontrar-indices-ausentes.sql`](sql-server/indexes/encontrar-indices-ausentes.sql) | Sugestões do otimizador — e por que **não** aplicar todas |
| [`encontrar-indices-nao-utilizados.sql`](sql-server/indexes/encontrar-indices-nao-utilizados.sql) | Índices que só custam escrita |
| [`encontrar-indices-duplicados-e-redundantes.sql`](sql-server/indexes/encontrar-indices-duplicados-e-redundantes.sql) | Cópias e prefixos |
| [`analisar-fragmentacao.sql`](sql-server/indexes/analisar-fragmentacao.sql) | Fragmentação com recomendação por índice |
| [`manutencao-de-indices.md`](sql-server/indexes/manutencao-de-indices.md) | `REBUILD` x `REORGANIZE` e o erro silencioso das rotinas |

### Espaço e crescimento

| Arquivo | Responde a |
|---|---|
| [`tamanho-das-tabelas.sql`](sql-server/espaco-e-crescimento/tamanho-das-tabelas.sql) | Quais tabelas ocupam mais espaço |
| [`tamanho-dos-indices.sql`](sql-server/espaco-e-crescimento/tamanho-dos-indices.sql) | Quanto cada índice ocupa, e se é lido |

### Administração

| Arquivo | Responde a |
|---|---|
| [`backup-e-restore.md`](sql-server/administracao/backup-e-restore.md) | RPO/RTO, recovery model, roteiro de restore |
| [`dbcc-checkdb-integridade.md`](sql-server/administracao/dbcc-checkdb-integridade.md) | Corrupção: detectar e o que fazer |
| [`permissoes-e-menor-privilegio.md`](sql-server/administracao/permissoes-e-menor-privilegio.md) | Sair do `sa` sem derrubar o sistema |
| [`shrink-quando-nao-usar.md`](sql-server/administracao/shrink-quando-nao-usar.md) | Por que `SHRINK` como rotina é destrutivo |

---

## C# e .NET

| Arquivo | Responde a |
|---|---|
| [`httpclient-uso-correto.md`](dotnet/httpclient/httpclient-uso-correto.md) | Esgotamento de sockets e DNS obsoleto |
| [`timeout-e-cancellation.md`](dotnet/httpclient/timeout-e-cancellation.md) | Os quatro timeouts da cadeia |
| [`resiliencia-retry-circuit-breaker.md`](dotnet/httpclient/resiliencia-retry-circuit-breaker.md) | Polly v8 e v7, backoff com jitter, circuit breaker |
| [`armadilhas-async-await.md`](dotnet/async-await/armadilhas-async-await.md) | Deadlock, `async void`, `Task.Run`, `ConfigureAwait` |
| [`tratamento-de-excecoes.md`](dotnet/excecoes/tratamento-de-excecoes.md) | O que capturar, `throw` x `throw ex`, log seguro |
| [`serializacao-json.md`](dotnet/json/serializacao-json.md) | `System.Text.Json` x `Newtonsoft.Json`, fuso, cultura |
| [`aplicacao-lenta-ou-travando.md`](dotnet/diagnostico/aplicacao-lenta-ou-travando.md) | Thread pool starvation, CPU, memória, dumps |

---

## Acesso a dados

| Tecnologia | Arquivo |
|---|---|
| **ADO.NET** | [`ado-net-fundamentos-seguros.md`](acesso-a-dados/ado-net/ado-net-fundamentos-seguros.md) |
| **ADO.NET** | [`connection-pool-esgotado.md`](acesso-a-dados/ado-net/connection-pool-esgotado.md) |
| **ADO.NET** | [`timeout-de-comando-vs-conexao.md`](acesso-a-dados/ado-net/timeout-de-comando-vs-conexao.md) |
| **Dapper** | [`dapper-receitas-essenciais.md`](acesso-a-dados/dapper/dapper-receitas-essenciais.md) |
| **EF Core** | [`ef-core-performance.md`](acesso-a-dados/entity-framework-core/ef-core-performance.md) |
| **EF6** | [`ef6-troubleshooting.md`](acesso-a-dados/entity-framework-6/ef6-troubleshooting.md) |

---

## APIs e integração

| Tema | Arquivo |
|---|---|
| Retry e idempotência | [`retry-seguro-e-idempotencia.md`](api-integracao/resiliencia/retry-seguro-e-idempotencia.md) |
| SOAP e WCF | [`consumir-soap-de-sistema-legado.md`](api-integracao/soap-wcf/consumir-soap-de-sistema-legado.md) |
| Autenticação | [`autenticacao-em-apis.md`](api-integracao/autenticacao/autenticacao-em-apis.md) |

---

## IIS

| Arquivo | Responde a |
|---|---|
| [`http-503-service-unavailable.md`](iis/troubleshooting/http-503-service-unavailable.md) | Application Pool parado, Rapid-Fail, fila cheia |
| [`http-500-e-http-502.md`](iis/troubleshooting/http-500-e-http-502.md) | Subcódigos, `web.config`, aplicação que não sobe |

---

## Sistemas legados

| Arquivo | Responde a |
|---|---|
| [`modernizacao-incremental-strangler.md`](sistemas-legados/modernizacao-incremental-strangler.md) | Strangler Fig, ACL, DI, logging, testes, migração de plataforma |
| [`legado-consumindo-api-rest-moderna.md`](sistemas-legados/legado-consumindo-api-rest-moderna.md) | TLS 1.2, `HttpClient`, deadlock, JSON, token |

---

## Checklists e templates

| Arquivo | Para quê |
|---|---|
| [`checklist-producao-sql-server.md`](checklists/checklist-producao-sql-server.md) | Assumir ou revisar uma instância |
| [`checklist-deployment-aplicacao-dotnet.md`](checklists/checklist-deployment-aplicacao-dotnet.md) | Antes de cada deploy |
| [`templates/`](templates/) | Seis modelos para expandir o repositório |

---

## Matriz de compatibilidade

### SQL Server

| Recurso usado neste repositório | Versão mínima |
|---|---|
| Piso geral dos scripts | **2012 (11.x)** |
| `open_transaction_count` em `sys.dm_exec_sessions` | 2012 (11.x) |
| `sys.dm_db_stats_properties` | 2012 SP1 (e 2008 R2 SP2) |
| Query Store | 2016 (13.x) |
| Colunas de *memory grant* em `sys.dm_exec_query_stats` | 2016 (13.x) |
| Limiar dinâmico de estatísticas por padrão | 2016 (13.x), compat. 130+ |
| Scalar UDF Inlining | 2019 (15.x) |
| Parameter Sensitive Plan optimization | 2022 (16.x) |

### .NET

| Recurso | Plataforma |
|---|---|
| `SocketsHttpHandler` / `PooledConnectionLifetime` | .NET Core 2.1+ |
| `IHttpClientFactory` | .NET Core 2.1+ e .NET Framework via `Microsoft.Extensions.Http` |
| `System.Text.Json` | .NET Core 3.0+ (pacote em .NET Framework) |
| Ferramentas `dotnet-counters` / `dotnet-dump` | .NET Core 3.0+ |
| `AsSplitQuery` (EF Core) | EF Core 5 |
| `ExecuteUpdate` / `ExecuteDelete` (EF Core) | EF Core 7 |
| Polly v8 (`ResiliencePipelineBuilder`) | .NET moderno — use Polly v7 em .NET Framework |
| `Microsoft.Extensions.Http.Resilience` | .NET 8+ |
| Cliente WCF | .NET Framework completo; .NET moderno via `System.ServiceModel.*` |
| **Servidor** WCF | .NET Framework; no .NET moderno, CoreWCF |

---

**Criado por Fábio Cerqueira**
