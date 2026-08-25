# Índice por tecnologia

> **Quero ver o que existe sobre...** Inventário completo do repositório, organizado por
> tecnologia.
>
> Navegação: **Tecnologia → Problema → Solução**

Se você sabe o sintoma mas não a causa, use [`INDICE-POR-SINTOMA.md`](INDICE-POR-SINTOMA.md).

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

### Espaço, crescimento e administração

| Arquivo | Responde a |
|---|---|
| [`tamanho-das-tabelas.sql`](sql-server/espaco-e-crescimento/tamanho-das-tabelas.sql) | Quais tabelas ocupam mais espaço |
| [`tamanho-dos-indices.sql`](sql-server/espaco-e-crescimento/tamanho-dos-indices.sql) | Quanto cada índice ocupa, e se é lido |
| [`backup-e-restore.md`](sql-server/administracao/backup-e-restore.md) | RPO/RTO, recovery model, roteiro de restore |
| [`dbcc-checkdb-integridade.md`](sql-server/administracao/dbcc-checkdb-integridade.md) | Corrupção: detectar e o que fazer |
| [`permissoes-e-menor-privilegio.md`](sql-server/administracao/permissoes-e-menor-privilegio.md) | Sair do `sa` sem derrubar o sistema |
| [`shrink-quando-nao-usar.md`](sql-server/administracao/shrink-quando-nao-usar.md) | Por que `SHRINK` como rotina é destrutivo |

---

## C# — fundamentos

| Arquivo | Responde a |
|---|---|
| [`datas-e-fuso-horario.md`](csharp/datas-e-fuso-horario.md) | `DateTimeOffset` x `DateTime`, UTC, `TimeZoneInfo`, `DATETIME2`, intervalo meio aberto |
| [`cultura-encoding-e-comparacao-de-strings.md`](csharp/cultura-encoding-e-comparacao-de-strings.md) | Cultura em números e datas, `StringComparison`, collation, encoding de arquivo |

## .NET — runtime e infraestrutura

| Arquivo | Responde a |
|---|---|
| [`httpclient-uso-correto.md`](dotnet/httpclient/httpclient-uso-correto.md) | Esgotamento de sockets e DNS obsoleto |
| [`timeout-e-cancellation.md`](dotnet/httpclient/timeout-e-cancellation.md) | Os quatro timeouts da cadeia |
| [`resiliencia-retry-circuit-breaker.md`](dotnet/httpclient/resiliencia-retry-circuit-breaker.md) | Polly v8 e v7, backoff com jitter, circuit breaker |
| [`armadilhas-async-await.md`](dotnet/async-await/armadilhas-async-await.md) | Deadlock, `async void`, `Task.Run`, `ConfigureAwait` |
| [`tratamento-de-excecoes.md`](dotnet/excecoes/tratamento-de-excecoes.md) | O que capturar, `throw` x `throw ex`, log seguro |
| [`serializacao-json.md`](dotnet/json/serializacao-json.md) | `System.Text.Json` x `Newtonsoft.Json`, fuso, cultura |
| [`log-estruturado-e-o-que-nunca-logar.md`](dotnet/logging/log-estruturado-e-o-que-nunca-logar.md) | Message templates, níveis, `BeginScope`, o que nunca registrar |
| [`correlation-id-e-rastreabilidade.md`](dotnet/logging/correlation-id-e-rastreabilidade.md) | Middleware, `DelegatingHandler`, W3C `traceparent`, `SESSION_CONTEXT` no SQL Server |
| [`tempos-de-vida-e-dependencia-cativa.md`](dotnet/dependency-injection/tempos-de-vida-e-dependencia-cativa.md) | `Scoped` preso em `Singleton`, `IServiceScopeFactory`, DI em legado |
| [`servico-em-segundo-plano-sem-derrubar-a-aplicacao.md`](dotnet/background-services/servico-em-segundo-plano-sem-derrubar-a-aplicacao.md) | `BackgroundService`, encerramento limpo, múltiplas instâncias |
| [`aplicacao-lenta-ou-travando.md`](dotnet/diagnostico/aplicacao-lenta-ou-travando.md) | Thread pool starvation, CPU, memória, dumps |

---

## ASP.NET

| Arquivo | Responde a |
|---|---|
| [`mapa-de-versoes-e-equivalencias.md`](aspnet/mapa-de-versoes-e-equivalencias.md) | Tradução WebForms / MVC 5 / Web API 2 → ASP.NET Core, e o que **não** tem equivalente |
| [`ordem-do-pipeline-de-middleware.md`](aspnet/aspnet-core/ordem-do-pipeline-de-middleware.md) | `[Authorize]` que não protege, CORS, arquivo estático, `IHttpModule` |

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
| XML, XSD e XXE | [`processar-xml-com-seguranca.md`](api-integracao/xml/processar-xml-com-seguranca.md) |
| Arquivo, CSV, posicional, SFTP | [`integracao-por-arquivo-csv-e-posicional.md`](api-integracao/arquivos/integracao-por-arquivo-csv-e-posicional.md) |

---

## Arquitetura

| Arquivo | Responde a |
|---|---|
| [`quando-usar-cada-padrao.md`](arquitetura/quando-usar-cada-padrao.md) | Repository, Unit of Work, CQRS, Mediator, SOLID, Clean Architecture — com o preço de cada um |
| [`consistencia-entre-sistemas-outbox-e-reconciliacao.md`](arquitetura/integracao/consistencia-entre-sistemas-outbox-e-reconciliacao.md) | Escrita dupla, outbox transacional, idempotência, compensação, reconciliação |

---

## Segurança

| Arquivo | Responde a |
|---|---|
| [`prevenir-e-encontrar-sql-injection.md`](seguranca/sql-injection/prevenir-e-encontrar-sql-injection.md) | Parametrização, `sp_executesql`, `QUOTENAME`, e **script de auditoria** do banco |
| [`gerenciamento-de-segredos-em-aplicacoes-dotnet.md`](seguranca/secrets/gerenciamento-de-segredos-em-aplicacoes-dotnet.md) | User Secrets, Key Vault, identidade gerenciada, `configSource`, `aspnet_regiis` |
| [`tls-e-certificados-em-dotnet.md`](seguranca/certificados/tls-e-certificados-em-dotnet.md) | Diagnosticar TLS sem desligar a validação, cadeia incompleta, mutual TLS |
| [`armazenamento-seguro-de-senhas.md`](seguranca/senhas/armazenamento-seguro-de-senhas.md) | PBKDF2, Argon2id, migração oportunista de MD5 |

---

## DevOps

| Arquivo | Responde a |
|---|---|
| [`comandos-git-de-emergencia.md`](devops/git/comandos-git-de-emergencia.md) | `reflog`, `revert`, `bisect`, `--force-with-lease`, `fsck` |
| [`remover-segredo-vazado-do-historico.md`](devops/git/remover-segredo-vazado-do-historico.md) | Rotação, `git-filter-repo`, push protection, prevenção |
| [`pipeline-ci-dotnet.md`](devops/github-actions/pipeline-ci-dotnet.md) | Build e teste, cache NuGet, segredos, runner Windows para .NET Framework |
| [`estrategias-de-deployment-e-rollback.md`](devops/deployment/estrategias-de-deployment-e-rollback.md) | Expand/contract, blue-green, canário, migração de banco, critérios de rollback |

---

## IIS e sistemas legados

| Arquivo | Responde a |
|---|---|
| [`http-503-service-unavailable.md`](iis/troubleshooting/http-503-service-unavailable.md) | Application Pool parado, Rapid-Fail, fila cheia |
| [`http-500-e-http-502.md`](iis/troubleshooting/http-500-e-http-502.md) | Subcódigos, `web.config`, aplicação que não sobe |
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
| `sp_executesql`, `QUOTENAME`, `OUTPUT`, `READPAST` | 2005 (9.x) |
| `open_transaction_count` em `sys.dm_exec_sessions` | 2012 (11.x) |
| `sys.dm_db_stats_properties` | 2012 SP1 (e 2008 R2 SP2) |
| Query Store | 2016 (13.x) |
| Colunas de *memory grant* em `sys.dm_exec_query_stats` | 2016 (13.x) |
| `sp_set_session_context` / `SESSION_CONTEXT()` | 2016 (13.x) |
| `BULK INSERT` com `CODEPAGE = '65001'` (UTF-8) | 2016 (13.x) |
| Limiar dinâmico de estatísticas por padrão | 2016 (13.x), compat. 130+ |
| Scalar UDF Inlining | 2019 (15.x) |
| Parameter Sensitive Plan optimization | 2022 (16.x) |

### .NET

| Recurso | Plataforma |
|---|---|
| `SocketsHttpHandler` / `PooledConnectionLifetime` | .NET Core 2.1+ |
| `IHttpClientFactory` | .NET Core 2.1+ e .NET Framework via `Microsoft.Extensions.Http` |
| `CryptographicOperations.FixedTimeEquals` | .NET Core 2.1+ e .NET Framework 4.7.2+ |
| `CodePagesEncodingProvider` | Necessário no .NET Core/5+; disponível por padrão no .NET Framework |
| `System.Text.Json` | .NET Core 3.0+ (pacote em .NET Framework) |
| `BackgroundService` / `Microsoft.Extensions.Hosting` | .NET Core 3.1+ |
| Ferramentas `dotnet-counters` / `dotnet-dump` | .NET Core 3.0+ |
| `DateOnly` / `TimeOnly` e IANA IDs no Windows | .NET 6+ |
| `PeriodicTimer` | .NET 6+ |
| `Stopwatch.GetElapsedTime` | .NET 7+ |
| `TimeProvider` | .NET 8+ |
| `AsSplitQuery` (EF Core) | EF Core 5 |
| `ExecuteUpdate` / `ExecuteDelete` (EF Core) | EF Core 7 |
| `FromSql` com interpolação (EF Core) | EF Core 8 |
| Polly v8 (`ResiliencePipelineBuilder`) | .NET moderno — use Polly v7 em .NET Framework |
| `Microsoft.Extensions.Http.Resilience` | .NET 8+ |
| `Encrypt=True` por padrão | `Microsoft.Data.SqlClient` 4.0+ |
| `Authentication=Active Directory Default` | `Microsoft.Data.SqlClient` 3.0+ |
| Entra ID em pacote separado (`Extensions.Azure`) | `Microsoft.Data.SqlClient` 7.0+ |
| ASP.NET Core sobre .NET Framework | Somente até ASP.NET Core 2.x |
| Cliente WCF | .NET Framework completo; .NET moderno via `System.ServiceModel.*` |
| **Servidor** WCF | .NET Framework; no .NET moderno, CoreWCF |

### Versões do .NET em suporte

| Versão | Tipo | Fim do suporte |
|---|---|---|
| .NET 10 | LTS | 14/11/2028 |
| .NET 9 | STS | 10/11/2026 |
| .NET 8 | LTS | 10/11/2026 |

---

**Criado por Fábio Cerqueira**
