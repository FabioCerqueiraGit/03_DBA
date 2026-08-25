# Changelog

Todas as mudanças relevantes deste repositório são registradas aqui.

O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/) e o
versionamento segue [Semantic Versioning](https://semver.org/lang/pt-BR/), adaptado ao
contexto de um repositório de documentação e scripts:

- **MAJOR** — reorganização estrutural que quebra links ou caminhos existentes.
- **MINOR** — novas áreas, novos scripts, novos documentos.
- **PATCH** — correções, ajustes de texto, correção de link, ajuste de script existente.

---

## [Não publicado]

Terceira fase planejada — ver "Sugestões para a próxima fase" no relatório de implantação.

---

## [1.1.0] — 2026-08-25

Segunda fase. Seis áreas novas, nenhuma remoção, nenhuma reorganização destrutiva. Todos os
caminhos da versão 1.0.0 continuam válidos.

### Adicionado

**`devops/` — nova área**

- `git/comandos-git-de-emergencia.md` — organizado por sintoma: commit no branch errado,
  `reset --hard` que levou trabalho junto, `revert` de commit publicado, `bisect`,
  `--force-with-lease`, recuperação por `reflog` e `fsck`.
- `git/remover-segredo-vazado-do-historico.md` — procedimento de resposta a incidente com a
  ordem correta das ações: rotacionar a credencial **antes** de limpar o histórico; reescrita com
  `git-filter-repo`; prevenção com push protection e User Secrets.
- `github-actions/pipeline-ci-dotnet.md` — workflow de build e teste com `permissions` mínimo,
  cache de NuGet, trava contra "zero testes executados", tratamento de segredos e job de MSBuild
  em runner Windows para projetos .NET Framework.
- `deployment/estrategias-de-deployment-e-rollback.md` — expand/contract, blue-green, canário,
  feature flag; tabela de retrocompatibilidade de mudanças de esquema; migração de banco no
  pipeline; critérios de rollback definidos antes do deployment.

**`seguranca/` — nova área**

- `sql-injection/prevenir-e-encontrar-sql-injection.md` — parametrização em ADO.NET, Dapper e
  Entity Framework; `sp_executesql` e `QUOTENAME`; lista branca para `ORDER BY` dinâmico; e um
  **script T-SQL de auditoria** que varre `sys.sql_modules` e classifica os objetos por risco,
  com procedures `EXECUTE AS` no topo da lista.
- `secrets/gerenciamento-de-segredos-em-aplicacoes-dotnet.md` — hierarquia de decisão de
  eliminar o segredo até arquivo local; User Secrets, Key Vault, identidade gerenciada,
  `configSource` e `aspnet_regiis` para o legado.
- `certificados/tls-e-certificados-em-dotnet.md` — diagnosticar por `SslPolicyErrors` em vez de
  desligar a validação; TLS 1.2 no .NET Framework; cadeia incompleta; mutual TLS e a permissão na
  chave privada sob IIS.
- `senhas/armazenamento-seguro-de-senhas.md` — parâmetros atuais de Argon2id, scrypt, bcrypt e
  PBKDF2; migração oportunista de MD5 no login, sem forçar redefinição.

**`aspnet/` — nova área**

- `mapa-de-versoes-e-equivalencias.md` — tabela de tradução entre WebForms, MVC 5, Web API 2 e
  ASP.NET Core para configuração, contexto, DI, roteamento, HTTP, log, sessão e assíncrono;
  o que **não** tem equivalente; e o caminho incremental com YARP e System.Web adapters.
- `aspnet-core/ordem-do-pipeline-de-middleware.md` — a ordem de referência e as três relações
  que explicam quase todo defeito; equivalência com `IHttpModule`.

**`csharp/` — nova área**

- `datas-e-fuso-horario.md` — escolha de tipo, UTC no armazenamento, `TimeProvider`,
  identificadores IANA e Windows, `tzdata` em contêiner, `DATETIME2` e intervalo meio aberto.
- `cultura-encoding-e-comparacao-de-strings.md` — cultura em números e datas,
  `StringComparison`, collation no SQL Server, `VARCHAR` x `NVARCHAR` e encoding de arquivo.

**`arquitetura/` — nova área**

- `quando-usar-cada-padrao.md` — Repository, Unit of Work, Service Layer, CQRS, Mediator,
  SOLID e Clean Architecture, cada um com a seção "quando **não** usar" preenchida de verdade.
- `integracao/consistencia-entre-sistemas-outbox-e-reconciliacao.md` — o problema da escrita
  dupla, outbox transacional com índice filtrado e reivindicação atômica, idempotência no
  consumidor, compensação e reconciliação.

**`dotnet/` — subtemas novos**

- `logging/` — log estruturado e o que nunca registrar; correlation ID propagado por middleware,
  `DelegatingHandler`, `traceparent` e `SESSION_CONTEXT` no SQL Server.
- `dependency-injection/tempos-de-vida-e-dependencia-cativa.md` — `Scoped` preso em `Singleton`,
  `IServiceScopeFactory`, `ValidateOnBuild` e introdução de DI em sistema legado.
- `background-services/servico-em-segundo-plano-sem-derrubar-a-aplicacao.md` — exceção que
  derruba o host, escopo por ciclo, encerramento limpo e coordenação entre instâncias.

**`api-integracao/` — subtemas novos**

- `xml/processar-xml-com-seguranca.md` — escolha de API, namespaces, encoding, cultura e
  prevenção de XXE; validação por XSD acumulando todos os erros; streaming.
- `arquivos/integracao-por-arquivo-csv-e-posicional.md` — arquivo incompleto, reprocessamento
  com hash, CSV lido com biblioteca, encoding, `SqlBulkCopy`, SFTP e reconciliação.

### Alterado

- `INDICE-POR-SINTOMA.md` — reescrito. Novas seções de segurança, Git/CI/deploy e ASP.NET, além
  da categoria **"dado errado sem nenhum erro"** (data com um dia a mais, valor mil vezes maior,
  acento corrompido), que é a mais difícil de encontrar por sintoma.
- `INDICE-POR-TECNOLOGIA.md` — inventário atualizado com as seis áreas novas; matriz de
  compatibilidade expandida com `SESSION_CONTEXT`, `CodePagesEncodingProvider`,
  `CryptographicOperations.FixedTimeEquals`, `DateOnly`/`TimeOnly`, `PeriodicTimer`,
  `TimeProvider`, versões do `Microsoft.Data.SqlClient` e datas de fim de suporte do .NET.
- `README.md` — árvore de estrutura, tabela de áreas e atalhos de emergência atualizados.

### Corrigido

- Acentuação em dois documentos (`negacao` → `negação`; `idempotênte` → `idempotente`).
- Query de reconciliação com `HAVING` sem `GROUP BY`, que não executaria.
- Valor de exemplo que se parecia demais com credencial real, substituído por placeholder
  explícito.

### Preservado

- `postgresql-audit-logger/` — intacto, sem qualquer alteração.
- `docs/projetos-dba-postgresql-mysql.md` — intacto.
- Todos os documentos e scripts da versão 1.0.0 — nenhum removido, nenhum caminho alterado.

---

## [1.0.0] — 2026-08-20

Primeira fase do "Canivete Suíço do Dev C#/.NET e do DBA SQL Server", construída sobre o
repositório existente sem remover nada do que já havia.

### Adicionado

**Fundação**

- `README.md` — central de comando com índice navegável, estrutura, convenções, matriz de
  compatibilidade de SQL Server e .NET, e política de segurança.
- `CONTRIBUTING.md` — padrão obrigatório de documentos, scripts T-SQL e código C#;
  regras de idioma, nomenclatura, segurança e compatibilidade.
- `LICENSE` — MIT.
- `.gitignore` — cobertura para build .NET, artefatos de SQL Server e, principalmente,
  formatos comuns de segredo.
- `.editorconfig` — padronização de encoding e indentação por tipo de arquivo.
- `INDICE-POR-SINTOMA.md` — navegação `Sintoma → Diagnóstico → Solução`.
- `INDICE-POR-TECNOLOGIA.md` — navegação `Tecnologia → Problema → Solução`.

**Templates**

- Modelos para script T-SQL, solução C#, roteiro de troubleshooting, integração de API,
  checklist operacional e decisão arquitetural.

**SQL Server**

- `troubleshooting/` — roteiro de diagnóstico de lentidão em oito passos, script de
  triagem rápida, análise de bloqueio (plano e árvore hierárquica), transações abertas
  de longa duração, captura e leitura de deadlocks a partir do `system_health`,
  investigação de crescimento de transaction log, diagnóstico de `tempdb` e procedimento
  seguro para encerrar sessão.
- `monitoramento/` — sessões e requests em execução, waits acumulados, waits em tempo
  real, memory grants, espaço em disco e arquivos, conexões por aplicação.
- `performance/` — top queries por CPU, por I/O e por duração; parameter sniffing;
  SARGability; leitura de plano de execução; diagnóstico de estatísticas.
- `indexes/` — índices ausentes, não utilizados, duplicados e redundantes; análise de
  fragmentação; política de manutenção.
- `espaco-e-crescimento/` — tamanho de tabelas e de índices.
- `administracao/` — backup e restore, recovery model, `DBCC CHECKDB`, permissões e
  menor privilégio, e um documento dedicado a quando **não** usar `SHRINK`.

**C# e .NET**

- `httpclient/` — uso correto, esgotamento de socket e DNS obsoleto, timeout e
  `CancellationToken`, resiliência com Polly v8 e `Microsoft.Extensions.Http.Resilience`.
- `async-await/` — armadilhas, deadlock por `sync-over-async`, `ConfigureAwait`.
- `excecoes/` — tratamento, exceções transitórias, o que nunca engolir.
- `json/` — `System.Text.Json` e `Newtonsoft.Json`, incluindo o caminho para legado.
- `diagnostico/` — aplicação lenta, travando ou consumindo memória.

**Acesso a dados**

- ADO.NET: fundamentos seguros, connection pool esgotado, timeout de comando versus
  timeout de conexão.
- Dapper: receitas essenciais.
- EF Core: performance e armadilhas.
- EF6: troubleshooting de sistemas .NET Framework.

**APIs e integração**

- Retry seguro e idempotência, consumo de SOAP a partir de sistema legado, autenticação
  em APIs.

**IIS**

- HTTP 503, HTTP 500 e HTTP 502 com roteiro de diagnóstico.

**Sistemas legados**

- Modernização incremental com Strangler Fig e Anti-Corruption Layer; sistema legado
  consumindo API REST moderna.

**Checklists**

- Checklist de produção para SQL Server e checklist de deployment de aplicação .NET.

### Preservado

- `postgresql-audit-logger/` — projeto anterior mantido intacto, sem qualquer alteração.
- Conteúdo original do `README.md` (projetos de DBA em PostgreSQL e MySQL) movido na
  íntegra para `docs/projetos-dba-postgresql-mysql.md` e referenciado no novo README.

### Alterado

- `README.md` da raiz passou a ser a central de comando do repositório. O conteúdo
  anterior não foi descartado — está preservado no arquivo citado acima.

---

**Criado por Fábio Cerqueira**
