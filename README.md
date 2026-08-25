# Canivete Suíço do Dev C#/.NET e do DBA SQL Server

> Manual operacional vivo, caixa de ferramentas e biblioteca de troubleshooting para quem
> desenvolve, mantém, integra e administra sistemas em C#/.NET e SQL Server — inclusive os
> sistemas legados que continuam pagando as contas.

Este repositório não é uma coleção de exemplos didáticos. É o conjunto de scripts, procedimentos,
padrões e decisões que um profissional acumula ao longo da carreira e quer encontrar **rápido**, de
preferência às três da manhã, com produção fora do ar.

Cada solução responde sempre às mesmas perguntas: *que problema isso resolve*, *quando usar*,
*quando **não** usar*, *qual o risco em produção* e *em quais versões funciona*.

---

## Emergência

| Situação | Vá direto para |
|---|---|
| "O SQL Server está lento" | [Roteiro de diagnóstico em 8 passos](sql-server/troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md) |
| "A aplicação travou" | [Diagnóstico de aplicação lenta](dotnet/diagnostico/aplicacao-lenta-ou-travando.md) |
| "HTTP 503 no IIS" | [HTTP 503 Service Unavailable](iis/troubleshooting/http-503-service-unavailable.md) |
| "Preciso fazer rollback" | [Estratégias de deployment e rollback](devops/deployment/estrategias-de-deployment-e-rollback.md) |
| "Vazei um segredo no Git" | [Segredo vazado em um commit](devops/git/remover-segredo-vazado-do-historico.md) |
| Outro sintoma | [**Índice por sintoma**](INDICE-POR-SINTOMA.md) |

Se você tem trinta segundos: rode
[`diagnostico-rapido-30-segundos.sql`](sql-server/troubleshooting/diagnostico-rapido-30-segundos.sql)
e **salve a saída em arquivo antes de tocar em qualquer coisa.**

---

## Índice

- [Como usar este repositório](#como-usar-este-reposit%C3%B3rio)
- [Os dois índices de navegação](#os-dois-%C3%ADndices-de-navega%C3%A7%C3%A3o)
- [Estrutura](#estrutura)
- [Áreas do repositório](#%C3%A1reas-do-reposit%C3%B3rio)
- [Compatibilidade](#compatibilidade)
- [Convenções](#conven%C3%A7%C3%B5es)
- [Segurança](#seguran%C3%A7a)
- [Templates](#templates)
- [Como contribuir](#como-contribuir)
- [Conteúdo anterior preservado](#conte%C3%BAdo-anterior-preservado)

---

## Como usar este repositório

| Situação | Ponto de partida |
|---|---|
| Você sabe **o sintoma**, mas não a causa (`"o SQL está lento"`, `"a API dá timeout"`) | [**Índice por sintoma**](INDICE-POR-SINTOMA.md) |
| Você sabe **a tecnologia** e quer ver o que existe (`Dapper`, `IIS`, `índices`) | [**Índice por tecnologia**](INDICE-POR-TECNOLOGIA.md) |
| Você lembra do nome do arquivo | Busque pelo nome — os arquivos são nomeados pelo que fazem: `encontrar-indices-nao-utilizados.sql` |

No GitHub, pressionar <kbd>t</kbd> na página do repositório abre a busca por nome de arquivo. Como
todo arquivo tem nome descritivo em português, digitar `bloqueio`, `deadlock` ou `timeout` costuma
bastar.

### Antes de rodar qualquer coisa em produção

Os scripts de **diagnóstico** deste repositório são somente leitura e seguros para produção, salvo
aviso explícito no cabeçalho do arquivo. Os comandos de **ação** (matar sessão, reconstruir índice,
alterar configuração) vêm com um bloco de aviso e comentados por padrão — você precisa
descomentá-los conscientemente.

Regra da casa: **nenhum script deste repositório deve ser executado em produção sem que você tenha
lido o cabeçalho dele.** O cabeçalho existe exatamente para isso.

---

## Os dois índices de navegação

O repositório é organizado por tecnologia, mas problema real raramente chega organizado por
tecnologia. Chega como sintoma. Por isso existem dois caminhos:

```text
Sintoma     ->  Diagnostico  ->  Solucao      ....  INDICE-POR-SINTOMA.md
Tecnologia  ->  Problema     ->  Solucao      ....  INDICE-POR-TECNOLOGIA.md
```

---

## Estrutura

```text
/
|-- INDICE-POR-SINTOMA.md          <- "estou com este problema..."
|-- INDICE-POR-TECNOLOGIA.md       <- "quero ver o que existe sobre..."
|
|-- sql-server/
|   |-- troubleshooting/           Diagnostico de incidente em producao
|   |-- monitoramento/             Visao do que esta acontecendo agora
|   |-- performance/               Queries, planos, estatisticas, CPU, I/O
|   |-- indexes/                   Ausentes, duplicados, nao usados, fragmentacao
|   |-- espaco-e-crescimento/      Tamanho de tabelas, indices e arquivos
|   `-- administracao/             Backup, restore, DBCC, permissoes, shrink
|
|-- csharp/                        Datas e fuso, cultura, encoding, comparacao
|
|-- dotnet/
|   |-- httpclient/                O erro mais caro do .NET, e como evita-lo
|   |-- async-await/               Deadlock, sync-over-async, CancellationToken
|   |-- excecoes/                  Tratamento, transitorio x permanente, log seguro
|   |-- json/                      System.Text.Json e Newtonsoft.Json
|   |-- logging/                   Log estruturado, correlation id, o que nunca logar
|   |-- dependency-injection/      Tempos de vida e dependencia cativa
|   |-- background-services/       Job que nao derruba a aplicacao
|   `-- diagnostico/               Aplicacao lenta, travando ou consumindo memoria
|
|-- aspnet/                        WebForms -> MVC 5 -> Web API 2 -> ASP.NET Core
|   `-- aspnet-core/               Ordem do pipeline de middleware
|
|-- acesso-a-dados/
|   |-- ado-net/                   SqlConnection, pooling, timeouts, parametrizacao
|   |-- dapper/                    Receitas essenciais
|   |-- entity-framework-core/     Performance e armadilhas
|   `-- entity-framework-6/        Manutencao de sistemas .NET Framework
|
|-- api-integracao/
|   |-- resiliencia/               Retry, backoff, circuit breaker, idempotencia
|   |-- soap-wcf/                  Consumir SOAP, inclusive do legado
|   |-- autenticacao/              Basic, Bearer, JWT, OAuth 2.0, certificados
|   |-- xml/                       XSD, namespaces, XXE, streaming
|   `-- arquivos/                  CSV, posicional, SFTP, reprocessamento
|
|-- arquitetura/
|   `-- integracao/                Outbox, idempotencia, compensacao, reconciliacao
|
|-- seguranca/
|   |-- sql-injection/             Prevenir na aplicacao, auditar o banco
|   |-- secrets/                   User Secrets, cofre, identidade gerenciada
|   |-- certificados/              TLS sem desligar a validacao
|   `-- senhas/                    PBKDF2, Argon2id, migracao de hash legado
|
|-- devops/
|   |-- git/                       Comandos de emergencia, segredo vazado
|   |-- github-actions/            Pipeline de CI para .NET
|   `-- deployment/                Expand/contract, blue-green, rollback
|
|-- iis/troubleshooting/           HTTP 500, 502, 503, Application Pool
|-- sistemas-legados/              Strangler, ACL, modernizacao incremental
|-- checklists/                    Listas de verificacao para producao e deploy
|-- templates/                     Modelos para expandir o repositorio
|
|-- docs/                          Documentacao de apoio
`-- postgresql-audit-logger/       Projeto anterior -- preservado
```

---

## Áreas do repositório

| Área | Do que trata | Comece por |
|---|---|---|
| **SQL Server** | A área mais densa. O que você roda **durante** um incidente, o que roda para entender o estado atual, e o que roda para investigar a fundo | [`sql-server/`](sql-server/README.md) |
| **C#** | Fundamentos que produzem defeito **sem gerar erro**: data, fuso, cultura, encoding, comparação de texto | [`csharp/`](csharp/README.md) |
| **.NET** | Erros que custam caro em produção: `HttpClient` mal usado, `async` bloqueado, DI com tempo de vida errado, job que derruba a API | [`dotnet/`](dotnet/README.md) |
| **ASP.NET** | A evolução de WebForms até o ASP.NET Core, com tabela de equivalências e o que **não** tem equivalente | [`aspnet/`](aspnet/README.md) |
| **Acesso a dados** | ADO.NET, Dapper, EF Core e EF6 — quatro formas de falar com o mesmo SQL Server, cada uma com armadilhas próprias | [`acesso-a-dados/`](acesso-a-dados/README.md) |
| **APIs e integração** | Retry que não duplica pedido, SOAP a partir do legado, XML sem XXE, arquivo que não reprocessa | [`api-integracao/`](api-integracao/README.md) |
| **Arquitetura** | Quando usar — e quando **não** usar — cada padrão; consistência entre sistemas com outbox e reconciliação | [`arquitetura/`](arquitetura/README.md) |
| **Segurança** | SQL Injection com script de auditoria, gestão de segredos, TLS, armazenamento de senhas | [`seguranca/`](seguranca/README.md) |
| **DevOps** | Git de emergência, segredo vazado, pipeline de CI, deployment e rollback — inclusive do banco | [`devops/`](devops/README.md) |
| **IIS** | Onde aplicações .NET morrem em silêncio: 503 com pool parado, 500.19 por `web.config`, 502.5 por runtime ausente | [`iis/`](iis/README.md) |
| **Sistemas legados** | Parte fundamental, não apêndice. Manter o antigo vivo **enquanto** se constrói o novo, sem a fantasia de reescrever tudo | [`sistemas-legados/`](sistemas-legados/README.md) |

---

## Compatibilidade

Funcionalidade moderna nunca é apresentada como universal. Todo documento e todo script declara a
compatibilidade no cabeçalho.

### SQL Server

| Versão | Nome interno | Observação |
|---|---|---|
| SQL Server 2012 | 11.x | Piso de compatibilidade da maioria dos scripts |
| SQL Server 2014 | 12.x | Novo estimador de cardinalidade |
| SQL Server 2016 | 13.x | Query Store; colunas de *memory grant*; `SESSION_CONTEXT` |
| SQL Server 2017 | 14.x | Adaptive Query Processing |
| SQL Server 2019 | 15.x | Intelligent Query Processing; Scalar UDF Inlining |
| SQL Server 2022 | 16.x | Parameter Sensitive Plan optimization |
| SQL Server 2025 | 17.x | Versão mais recente na linha on-premises |
| Azure SQL Database / MI | — | Nem toda DMV de instância existe; documentado quando relevante |

### .NET

| Plataforma | Situação | Uso típico |
|---|---|---|
| .NET Framework 4.6.2 – 4.8.1 | Suportada; segue o ciclo do Windows | Sistemas legados, WebForms, WCF, EF6 |
| .NET 8 (LTS) | Fim de suporte em **10/11/2026** | Base instalada muito grande |
| .NET 9 (STS) | Fim de suporte em **10/11/2026** | |
| .NET 10 (LTS) | LTS atual, suporte até **14/11/2028** | Alvo recomendado para código novo |

Quando existe diferença relevante entre plataformas, o documento apresenta o caminho na ordem
**Legado → Intermediário → Moderno**, em vez de fingir que a solução moderna se aplica a tudo.

A matriz completa de recursos por versão está em
[`INDICE-POR-TECNOLOGIA.md`](INDICE-POR-TECNOLOGIA.md#matriz-de-compatibilidade).

---

## Convenções

**Nomes de arquivo** descrevem a ação ou o problema, em português, minúsculas, separados por
hífen, sem acentos:

```text
OK    encontrar-sessoes-bloqueadoras.sql
OK    por-que-o-transaction-log-esta-crescendo.md
NAO   script1.sql   teste.sql   query_final_v2.sql
```

**Idioma**: toda a documentação está em português do Brasil. Código — T-SQL, C#, PowerShell, XML,
JSON, YAML — permanece na linguagem original, com termos técnicos oficiais preservados
(`ShouldHandle`, `SET TRANSACTION ISOLATION LEVEL`, `Application Pool`). Comentários explicativos
dentro do código estão em português; nos arquivos `.sql`, sem acentuação, para evitar problema de
collation e de editor em servidores antigos.

**Estrutura dos documentos**: cada solução é autocontida e segue o padrão dos
[templates](templates/). Um documento não deve exigir que você leia outros três antes de conseguir
usá-lo.

**Scripts T-SQL** trazem um cabeçalho padronizado com objetivo, compatibilidade, impacto em
produção, permissões necessárias, tempo estimado e limitações conhecidas — e terminam com um
bloco **"COMO LER O RESULTADO"**.

---

## Segurança

Nenhum arquivo deste repositório contém — e nenhuma contribuição deve conter — senha real,
connection string de ambiente real, token, API key, certificado privado ou credencial de qualquer
natureza. Onde um valor sensível seria necessário, existe um placeholder explícito:

```text
Server=<SERVIDOR>;Database=<BANCO>;User Id=<USUARIO>;Password=<SENHA>;
```

Os scripts T-SQL de diagnóstico não expõem dados de negócio: eles leem metadados e DMVs, não
tabelas de aplicação. O texto de queries capturado das DMVs **pode** conter valores literais
embutidos por aplicações que não parametrizam — trate a saída desses scripts com o mesmo cuidado
que trataria um log de produção.

A área [`seguranca/`](seguranca/README.md) trata do tema como conteúdo: SQL Injection, gestão de
segredos, TLS e armazenamento de senhas.

---

## Templates

Para que o repositório continue crescendo com o mesmo padrão, existem modelos prontos:

| Template | Use quando for documentar... |
|---|---|
| [`template-script-sql.md`](templates/template-script-sql.md) | Um script T-SQL de diagnóstico ou manutenção |
| [`template-solucao-csharp.md`](templates/template-solucao-csharp.md) | Um padrão ou solução em C#/.NET |
| [`template-troubleshooting.md`](templates/template-troubleshooting.md) | Um roteiro de diagnóstico de sintoma |
| [`template-integracao-api.md`](templates/template-integracao-api.md) | Uma integração entre sistemas |
| [`template-checklist.md`](templates/template-checklist.md) | Uma lista de verificação operacional |
| [`template-decisao-arquitetural.md`](templates/template-decisao-arquitetural.md) | Uma decisão de arquitetura e suas consequências |

---

## Como contribuir

Leia o [`CONTRIBUTING.md`](CONTRIBUTING.md). Em resumo: use o template correspondente, declare
compatibilidade, explique quando **não** usar a solução, e não coloque segredo nenhum no commit.

O histórico de mudanças está em [`CHANGELOG.md`](CHANGELOG.md).

---

## Conteúdo anterior preservado

Este repositório começou como um portfólio de projetos de DBA em PostgreSQL e MySQL. Esse conteúdo
continua aqui, intacto:

- [`postgresql-audit-logger/`](postgresql-audit-logger/) — solução de auditoria avançada em PostgreSQL com triggers, `pgcrypto` e Row-Level Security.
- [`docs/projetos-dba-postgresql-mysql.md`](docs/projetos-dba-postgresql-mysql.md) — descrição original dos quatro projetos de DBA PostgreSQL/MySQL, preservada na íntegra.

---

## Aviso

O conteúdo deste repositório é fornecido como está, para fins de referência técnica. Scripts que
alteram estado de banco de dados, configuração de servidor ou aplicação devem ser validados em
ambiente de teste antes de qualquer uso em produção. A responsabilidade pela execução é de quem
executa.

Licença: [MIT](LICENSE).

---

**Criado por Fábio Cerqueira**
