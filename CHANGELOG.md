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

Segunda fase planejada. Candidatos prioritários:

- ASP.NET Core: middleware, filtros, model binding, autorização baseada em política.
- Logging estruturado e observabilidade ponta a ponta (correlation ID, tracing).
- Filas e processamento assíncrono (Service Bus, RabbitMQ, Outbox pattern).
- SQL Server: Query Store em profundidade, Availability Groups, particionamento,
  compressão de dados.
- Integração por arquivo: SFTP, FTP, CSV posicional, reconciliação em lote.
- Git, GitHub Actions e pipelines de CI/CD.
- Segurança: SQL Injection em profundidade, gestão de segredos, TLS e certificados.
- WebForms e ASP.NET MVC 5: manutenção e armadilhas específicas.

---

## [1.0.0] — 2026-08-20

Primeira fase do "Canivete Suíço do Dev C#/.NET e do DBA SQL Server", construída sobre o
repositório existente **sem remover nada do que já havia**.

### Adicionado

**Fundação e navegação**

- `README.md` — central de comando com bloco de emergência, índice navegável, estrutura,
  convenções, matriz de compatibilidade de SQL Server e .NET, e política de segurança.
- `INDICE-POR-SINTOMA.md` — navegação `Sintoma → Diagnóstico → Solução`, com mapa em
  árvore e entradas escritas como o problema chega ao profissional.
- `INDICE-POR-TECNOLOGIA.md` — navegação `Tecnologia → Problema → Solução`, com o
  inventário completo e a matriz de recursos por versão.
- `CONTRIBUTING.md` — padrão obrigatório de documentos, scripts T-SQL e código C#; regras
  de idioma, nomenclatura, segurança e compatibilidade.
- `LICENSE` — MIT.
- `.gitignore` — build .NET, artefatos de SQL Server e, principalmente, formatos comuns de
  segredo.
- `.editorconfig` — encoding e indentação por tipo de arquivo.

**Templates** (6)

- Modelos para script T-SQL, solução C#, roteiro de troubleshooting, integração de API,
  checklist operacional e decisão arquitetural (ADR).

**SQL Server** (28 arquivos)

- `troubleshooting/` — roteiro âncora de lentidão em oito passos com árvore de decisão;
  triagem rápida; análise de bloqueio (pares e árvore hierárquica com a sessão raiz);
  transações abertas de longa duração; extração de deadlocks da `system_health`; guia de
  interpretação de deadlock; crescimento de transaction log; diagnóstico de `tempdb`;
  procedimento seguro para `KILL` com avaliação de custo de rollback.
- `monitoramento/` — sessões e requests em execução, waits em tempo real, waits
  acumulados com classificação por família, memory grants e fila de memória, espaço em
  disco e latência real de I/O por arquivo.
- `performance/` — top queries por CPU, por I/O e por duração (com bloco de Query Store);
  leitura de plano de execução em cinco passos; estatísticas desatualizadas; parameter
  sniffing; SARGability.
- `indexes/` — índices ausentes (com alerta explícito contra aplicar a lista em bloco),
  não utilizados, duplicados e redundantes por prefixo, fragmentação, e política de
  manutenção.
- `espaco-e-crescimento/` — tamanho de tabelas e de índices.
- `administracao/` — backup e restore, `DBCC CHECKDB`, permissões e menor privilégio, e um
  documento dedicado a quando **não** usar `SHRINK`.

**C# e .NET** (8 arquivos)

- `httpclient/` — uso correto (esgotamento de sockets e DNS obsoleto), timeout e
  `CancellationToken`, resiliência com Polly v8 e `Microsoft.Extensions.Http.Resilience`.
- `async-await/` — deadlock em ASP.NET clássico, `async void`, `Task.Run` indevido,
  `ConfigureAwait`.
- `excecoes/` — o que capturar, `throw` versus `throw ex`, transitório versus permanente.
- `json/` — `System.Text.Json` e `Newtonsoft.Json`, fuso horário, cultura, DTOs.
- `diagnostico/` — roteiro por padrão de CPU e memória, thread pool starvation, dumps.

**Acesso a dados** (7 arquivos)

- ADO.NET: fundamentos seguros, connection pool esgotado, `CommandTimeout` versus
  `Connect Timeout`.
- Dapper: receitas essenciais, `splitOn`, `QueryMultiple`, `SqlBulkCopy`.
- EF Core: `N+1`, explosão cartesiana, tracking, operações em massa, migrations.
- EF6: lazy loading ligado por padrão, `AutoDetectChanges`, erros clássicos.

**APIs e integração** (4 arquivos)

- Retry seguro e idempotência, com classificação de falha (incluindo o caso
  **indeterminado**) e reconciliação.
- SOAP e WCF do .NET Framework ao .NET 10.
- Autenticação: API Key, Basic, JWT, OAuth 2.0 client credentials, mTLS.

**IIS** (3 arquivos)

- HTTP 503 com Application Pool e Rapid-Fail Protection; tabela de subcódigos de HTTP 500
  e 502; diagnóstico de memory leak.

**Sistemas legados** (3 arquivos)

- Modernização incremental com Strangler Fig e Anti-Corruption Layer, introdução de DI e
  de logging, testes de caracterização, roteiro de migração de plataforma.
- Sistema legado consumindo API REST moderna: TLS 1.2, `HttpClient`, deadlock, JSON, token.

**Checklists** (3 arquivos)

- Instância SQL Server em produção e deployment de aplicação .NET, ambos com critérios de
  rollback e a lista dos itens que mais causam incidente.

### Preservado

- `postgresql-audit-logger/` — projeto anterior mantido **byte a byte**, sem qualquer
  alteração (verificado por comparação de SHA das árvores e blobs).
- Conteúdo original do `README.md` (projetos de DBA em PostgreSQL e MySQL) preservado na
  íntegra em `docs/projetos-dba-postgresql-mysql.md` e referenciado no novo README.

### Alterado

- `README.md` da raiz passou a ser a central de comando do repositório. O conteúdo anterior
  não foi descartado — está preservado no arquivo citado acima.

### Verificado

- **444 links internos** conferidos automaticamente; nenhum quebrado.
- Assinatura `**Criado por Fábio Cerqueira**` presente em todos os documentos criados.
- Nenhuma atribuição de autoria a ferramenta de IA.
- Nenhum segredo, credencial, nome de servidor ou dado real.
- Nenhuma acentuação em arquivos `.sql`, conforme a convenção do repositório.
- Versões e APIs confirmadas na documentação oficial da Microsoft e do Polly antes da
  publicação.

---

**Criado por Fábio Cerqueira**
