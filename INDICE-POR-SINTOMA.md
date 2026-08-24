# Índice por sintoma

> **Estou enfrentando um problema.** Encontre pelo sintoma, como ele chega até você — não pelo
> nome técnico da causa, que é justamente o que você ainda não sabe.
>
> Navegação: **Sintoma → Diagnóstico → Solução**

Para navegar por tecnologia, veja [`INDICE-POR-TECNOLOGIA.md`](INDICE-POR-TECNOLOGIA.md).

---

## Mapa rápido

```text
Estou enfrentando um problema...
│
├─ BANCO DE DADOS
│   ├─ O SQL Server esta lento          ├─ O tempdb encheu
│   ├─ O banco esta bloqueado           ├─ O banco esta crescendo
│   ├─ Existe deadlock                  ├─ Uma query ficou lenta
│   └─ O transaction log esta crescendo └─ O disco vai encher
│
├─ APLICACAO
│   ├─ A aplicacao esta lenta ou travou ├─ Nao consigo conectar no banco
│   ├─ A memoria cresce ate reciclar    ├─ Data com um dia a mais
│   ├─ Valor virou mil vezes maior      ├─ Acento virou caractere estranho
│   └─ Funciona local e falha em producao
│
├─ API E INTEGRACAO
│   ├─ A API retorna timeout            ├─ O JSON nao desserializa
│   ├─ A chamada SOAP falha             ├─ O XML nao e processado
│   ├─ Erro de certificado / TLS        ├─ Processado em duplicidade
│   └─ Gravou aqui e nao chegou la      └─ O arquivo processou pela metade
│
├─ ASP.NET E IIS
│   ├─ HTTP 503                         ├─ HTTP 500 / 502
│   └─ [Authorize] nao esta protegendo  └─ O job derrubou a API
│
└─ SEGURANCA E DEPLOY
    ├─ Vazei um segredo no Git          ├─ Esse sistema e injetavel?
    ├─ As senhas estao em MD5           ├─ Preciso fazer rollback
    └─ Commitei errado / perdi commits  └─ O deployment falhou
```

---

## Banco de dados

### "O SQL Server está lento"

**Comece aqui:** [roteiro de diagnóstico em 8 passos](sql-server/troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md)

| Passo | Rode | Se... |
|---|---|---|
| Triagem | [`diagnostico-rapido-30-segundos.sql`](sql-server/troubleshooting/diagnostico-rapido-30-segundos.sql) | — |
| É bloqueio? | [`quem-esta-bloqueando-quem.sql`](sql-server/troubleshooting/quem-esta-bloqueando-quem.sql) | Retornou linhas → bloqueio |
| É CPU? | [`queries-que-mais-consomem-cpu.sql`](sql-server/performance/queries-que-mais-consomem-cpu.sql) | Uma query domina → otimize-a |
| É I/O? | [`queries-que-mais-fazem-io.sql`](sql-server/performance/queries-que-mais-fazem-io.sql) | Lê muito e devolve pouco → falta índice |
| É memória? | [`memory-grants-e-fila-de-memoria.sql`](sql-server/monitoramento/memory-grants-e-fila-de-memoria.sql) | Linhas "NA FILA" → pressão de memória |
| Esperando o quê? | [`waits-em-tempo-real.sql`](sql-server/monitoramento/waits-em-tempo-real.sql) | — |

### "Quem está bloqueando quem?" / "o banco travou"

1. [`quem-esta-bloqueando-quem.sql`](sql-server/troubleshooting/quem-esta-bloqueando-quem.sql) — pares bloqueador/bloqueado
2. [`arvore-de-bloqueio-hierarquica.sql`](sql-server/troubleshooting/arvore-de-bloqueio-hierarquica.sql) — **a sessão RAIZ**, a única que importa
3. [`encontrar-transacoes-abertas-longa-duracao.sql`](sql-server/troubleshooting/encontrar-transacoes-abertas-longa-duracao.sql) — transação esquecida
4. Antes de matar: [`matar-sessao-com-seguranca.md`](sql-server/troubleshooting/matar-sessao-com-seguranca.md)

**Causas mais frequentes:** transação aberta e abandonada — ver
[`ado-net-fundamentos-seguros.md`](acesso-a-dados/ado-net/ado-net-fundamentos-seguros.md) — ou
chamada HTTP dentro de transação aberta, ver
[`arquitetura/quando-usar-cada-padrao.md`](arquitetura/quando-usar-cada-padrao.md).

### "Erro 1205 — deadlock"

1. [`extrair-deadlocks-do-system-health.sql`](sql-server/troubleshooting/extrair-deadlocks-do-system-health.sql) — já estão gravados
2. [`investigar-deadlocks.md`](sql-server/troubleshooting/investigar-deadlocks.md) — ler o grafo e corrigir

> **Erro 1222** não é deadlock, é timeout de lock → trate como bloqueio.

### "O transaction log está crescendo"

1. [`por-que-o-transaction-log-esta-crescendo.md`](sql-server/troubleshooting/por-que-o-transaction-log-esta-crescendo.md)
2. [`diagnosticar-crescimento-transaction-log.sql`](sql-server/troubleshooting/diagnosticar-crescimento-transaction-log.sql)

> **Não** troque o recovery model para `SIMPLE` para resolver: isso quebra a cadeia de backup e
> elimina o restore point-in-time, em silêncio.

### "O tempdb encheu"

[`diagnosticar-tempdb.md`](sql-server/troubleshooting/diagnosticar-tempdb.md) →
[`analisar-uso-do-tempdb.sql`](sql-server/troubleshooting/analisar-uso-do-tempdb.sql)

| Categoria dominante | Causa | Onde corrigir |
|---|---|---|
| Version store | Transação antiga aberta | [`encontrar-transacoes-abertas-longa-duracao.sql`](sql-server/troubleshooting/encontrar-transacoes-abertas-longa-duracao.sql) |
| Objetos internos | Spill por estimativa errada | [`estatisticas-desatualizadas.md`](sql-server/performance/estatisticas-desatualizadas.md) |
| Objetos de usuário | Tabelas temporárias grandes | Revisar o código |

### "Por que o banco está crescendo?"

[`tamanho-das-tabelas.sql`](sql-server/espaco-e-crescimento/tamanho-das-tabelas.sql) →
[`tamanho-dos-indices.sql`](sql-server/espaco-e-crescimento/tamanho-dos-indices.sql) →
[`espaco-em-disco-e-arquivos-do-banco.sql`](sql-server/monitoramento/espaco-em-disco-e-arquivos-do-banco.sql)

> Antes de `SHRINK`: [`shrink-quando-nao-usar.md`](sql-server/administracao/shrink-quando-nao-usar.md)

### "Essa query era rápida na semana passada"

| Suspeita | Onde ler |
|---|---|
| Estatística desatualizada | [`estatisticas-desatualizadas.md`](sql-server/performance/estatisticas-desatualizadas.md) |
| Parameter sniffing | [`parameter-sniffing.md`](sql-server/performance/parameter-sniffing.md) |
| Índice ausente ou removido | [`encontrar-indices-ausentes.sql`](sql-server/indexes/encontrar-indices-ausentes.sql) |
| Predicado não SARGable | [`sargability-e-indices-ignorados.md`](sql-server/performance/sargability-e-indices-ignorados.md) |
| Plano novo após deployment | [`estrategias-de-deployment-e-rollback.md`](devops/deployment/estrategias-de-deployment-e-rollback.md) |
| Como ler o plano | [`como-ler-um-plano-de-execucao.md`](sql-server/performance/como-ler-um-plano-de-execucao.md) |

### "O índice existe mas o SQL Server não usa"

→ [`sargability-e-indices-ignorados.md`](sql-server/performance/sargability-e-indices-ignorados.md)

Causa muito frequente vinda da aplicação: `AddWithValue` gerando `NVARCHAR` contra coluna
`VARCHAR` → [`cultura-encoding-e-comparacao-de-strings.md`](csharp/cultura-encoding-e-comparacao-de-strings.md).

---

## Aplicação

### "A aplicação está lenta" ou "travou"

**Comece aqui:** [`aplicacao-lenta-ou-travando.md`](dotnet/diagnostico/aplicacao-lenta-ou-travando.md)

| CPU | Memória | Provavelmente | Onde ir |
|---|---|---|---|
| **Baixa** | Estável | Threads bloqueadas | [`armadilhas-async-await.md`](dotnet/async-await/armadilhas-async-await.md) |
| Alta | Estável | Trabalho de CPU ou GC | [`aplicacao-lenta-ou-travando.md`](dotnet/diagnostico/aplicacao-lenta-ou-travando.md) |
| Baixa | **Crescendo** | Vazamento | [`aplicacao-lenta-ou-travando.md`](dotnet/diagnostico/aplicacao-lenta-ou-travando.md) |
| Baixa | Estável, banco ocupado | O gargalo é o banco | [roteiro do SQL Server](sql-server/troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md) |

### Erros de conexão e de tempo

| Sintoma | Documento |
|---|---|
| "Timeout expired" ao **conectar** | [`connection-pool-esgotado.md`](acesso-a-dados/ado-net/connection-pool-esgotado.md) |
| Timeout ao **executar** o comando | [`timeout-de-comando-vs-conexao.md`](acesso-a-dados/ado-net/timeout-de-comando-vs-conexao.md) |
| A página nunca responde, sem erro e sem CPU | [`armadilhas-async-await.md`](dotnet/async-await/armadilhas-async-await.md) |
| "A second operation was started on this context instance" | [`tempos-de-vida-e-dependencia-cativa.md`](dotnet/dependency-injection/tempos-de-vida-e-dependencia-cativa.md) |
| `ObjectDisposedException` em `DbContext` | [`tempos-de-vida-e-dependencia-cativa.md`](dotnet/dependency-injection/tempos-de-vida-e-dependencia-cativa.md) |

### Dado errado sem nenhum erro

Esta categoria é a mais perigosa: não há exceção, só dado incorreto.

| Sintoma | Causa provável | Documento |
|---|---|---|
| Data com um dia a mais ou a menos | `DateTime` convertido para UTC | [`datas-e-fuso-horario.md`](csharp/datas-e-fuso-horario.md) |
| Horário com 3 horas de diferença | Servidor em UTC, `DateTime.Now` no código | [`datas-e-fuso-horario.md`](csharp/datas-e-fuso-horario.md) |
| Registro das 23:59:59 sumiu do fechamento | `DATETIME` arredondando, ou `BETWEEN` | [`datas-e-fuso-horario.md`](csharp/datas-e-fuso-horario.md) |
| Valor virou mil vezes maior | Cultura na conversão de decimal | [`cultura-encoding-e-comparacao-de-strings.md`](csharp/cultura-encoding-e-comparacao-de-strings.md) |
| `José` virou `Jos�` ou `JosÃ©` | Encoding do arquivo | [`cultura-encoding-e-comparacao-de-strings.md`](csharp/cultura-encoding-e-comparacao-de-strings.md) |
| A busca não acha o registro que existe | Collation ou acento | [`cultura-encoding-e-comparacao-de-strings.md`](csharp/cultura-encoding-e-comparacao-de-strings.md) |
| `TimeZoneNotFoundException` em contêiner | `tzdata` ausente na imagem | [`datas-e-fuso-horario.md`](csharp/datas-e-fuso-horario.md) |

### "Funciona local e falha em produção"

| Suspeita | Onde ler |
|---|---|
| TLS 1.2 não habilitado | [`tls-e-certificados-em-dotnet.md`](seguranca/certificados/tls-e-certificados-em-dotnet.md) |
| Permissão na chave privada do certificado | [`tls-e-certificados-em-dotnet.md`](seguranca/certificados/tls-e-certificados-em-dotnet.md) |
| Identidade do Application Pool sem permissão | [`http-503-service-unavailable.md`](iis/troubleshooting/http-503-service-unavailable.md) |
| Cultura ou fuso diferentes no servidor | [`csharp/README.md`](csharp/README.md) |
| Segredo não provisionado no ambiente | [`gerenciamento-de-segredos-em-aplicacoes-dotnet.md`](seguranca/secrets/gerenciamento-de-segredos-em-aplicacoes-dotnet.md) |
| Volume de dados muito maior | [roteiro do SQL Server](sql-server/troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md) |

---

## API e integração

| Sintoma | Documento |
|---|---|
| A API retorna timeout | [`timeout-e-cancellation.md`](dotnet/httpclient/timeout-e-cancellation.md) |
| Funciona em teste e falha sob carga | [`httpclient-uso-correto.md`](dotnet/httpclient/httpclient-uso-correto.md) |
| A integração falha de vez em quando | [`resiliencia-retry-circuit-breaker.md`](dotnet/httpclient/resiliencia-retry-circuit-breaker.md) |
| O pedido foi processado em duplicidade | [`retry-seguro-e-idempotencia.md`](api-integracao/resiliencia/retry-seguro-e-idempotencia.md) |
| **Gravou aqui e não chegou lá** | [`consistencia-entre-sistemas-outbox-e-reconciliacao.md`](arquitetura/integracao/consistencia-entre-sistemas-outbox-e-reconciliacao.md) |
| O JSON não desserializa | [`serializacao-json.md`](dotnet/json/serializacao-json.md) |
| O XML não é processado | [`processar-xml-com-seguranca.md`](api-integracao/xml/processar-xml-com-seguranca.md) |
| A chamada SOAP falha | [`consumir-soap-de-sistema-legado.md`](api-integracao/soap-wcf/consumir-soap-de-sistema-legado.md) |
| "Could not create SSL/TLS secure channel" | [`tls-e-certificados-em-dotnet.md`](seguranca/certificados/tls-e-certificados-em-dotnet.md) |
| HTTP 401 / 403 na integração | [`autenticacao-em-apis.md`](api-integracao/autenticacao/autenticacao-em-apis.md) |
| O arquivo foi processado pela metade, ou duas vezes | [`integracao-por-arquivo-csv-e-posicional.md`](api-integracao/arquivos/integracao-por-arquivo-csv-e-posicional.md) |

> **Sobre erro de certificado:** a correção que aparece primeiro no buscador —
> `ServerCertificateValidationCallback = ... => true` — não conserta nada e desliga a autenticação
> do TLS. O caminho para achar a causa real está no documento acima.

---

## ASP.NET e IIS

| Sintoma | Documento |
|---|---|
| HTTP 503 Service Unavailable | [`http-503-service-unavailable.md`](iis/troubleshooting/http-503-service-unavailable.md) |
| HTTP 500.x ou HTTP 502.5 | [`http-500-e-http-502.md`](iis/troubleshooting/http-500-e-http-502.md) |
| `[Authorize]` não está protegendo o endpoint | [`ordem-do-pipeline-de-middleware.md`](aspnet/aspnet-core/ordem-do-pipeline-de-middleware.md) |
| CORS configurado e mesmo assim bloqueado | [`ordem-do-pipeline-de-middleware.md`](aspnet/aspnet-core/ordem-do-pipeline-de-middleware.md) |
| Arquivo protegido acessível sem login | [`ordem-do-pipeline-de-middleware.md`](aspnet/aspnet-core/ordem-do-pipeline-de-middleware.md) |
| Endpoint migrado passou a receber `null` | [`mapa-de-versoes-e-equivalencias.md`](aspnet/mapa-de-versoes-e-equivalencias.md) |
| `HttpContext.Current` não existe mais | [`mapa-de-versoes-e-equivalencias.md`](aspnet/mapa-de-versoes-e-equivalencias.md) |
| Um job derrubou a API inteira | [`servico-em-segundo-plano-sem-derrubar-a-aplicacao.md`](dotnet/background-services/servico-em-segundo-plano-sem-derrubar-a-aplicacao.md) |
| Após escalar, tudo processa em duplicidade | [`servico-em-segundo-plano-sem-derrubar-a-aplicacao.md`](dotnet/background-services/servico-em-segundo-plano-sem-derrubar-a-aplicacao.md) |

**⚠️ `[Authorize]` que não protege é falha de segurança silenciosa** — não gera erro nem log.
`UseAuthorization()` registrado antes de `UseAuthentication()`, ou ambos antes de `UseRouting()`.

---

## Segurança

| Sintoma / pergunta | Documento |
|---|---|
| **Vazei uma senha ou token em um commit** | [`remover-segredo-vazado-do-historico.md`](devops/git/remover-segredo-vazado-do-historico.md) |
| "Esse sistema é injetável? Como eu descubro?" | [`prevenir-e-encontrar-sql-injection.md`](seguranca/sql-injection/prevenir-e-encontrar-sql-injection.md) |
| As senhas dos usuários estão em MD5 | [`armazenamento-seguro-de-senhas.md`](seguranca/senhas/armazenamento-seguro-de-senhas.md) |
| Onde a connection string deveria estar? | [`gerenciamento-de-segredos-em-aplicacoes-dotnet.md`](seguranca/secrets/gerenciamento-de-segredos-em-aplicacoes-dotnet.md) |
| Erro de certificado após migrar de driver | [`tls-e-certificados-em-dotnet.md`](seguranca/certificados/tls-e-certificados-em-dotnet.md) |
| Quem pode o quê no banco? | [`permissoes-e-menor-privilegio.md`](sql-server/administracao/permissoes-e-menor-privilegio.md) |

> **A primeira ação diante de um segredo vazado não é técnica — é rotacionar a credencial.**
> Limpar o histórico do Git é higiene, não remediação.

---

## Git, CI e deploy

| Sintoma | Documento |
|---|---|
| Commitei no branch errado | [`comandos-git-de-emergencia.md`](devops/git/comandos-git-de-emergencia.md) |
| Rodei `reset --hard` e perdi commits | [`comandos-git-de-emergencia.md`](devops/git/comandos-git-de-emergencia.md) |
| Preciso desfazer um commit já enviado | [`comandos-git-de-emergencia.md`](devops/git/comandos-git-de-emergencia.md) |
| "Quando isso quebrou?" | [`comandos-git-de-emergencia.md`](devops/git/comandos-git-de-emergencia.md) |
| O pipeline passa mas nenhum teste roda | [`pipeline-ci-dotnet.md`](devops/github-actions/pipeline-ci-dotnet.md) |
| **Preciso fazer rollback** | [`estrategias-de-deployment-e-rollback.md`](devops/deployment/estrategias-de-deployment-e-rollback.md) |
| A migração de banco não pode voltar | [`estrategias-de-deployment-e-rollback.md`](devops/deployment/estrategias-de-deployment-e-rollback.md) |
| O deployment falhou | [`checklist-deployment-aplicacao-dotnet.md`](checklists/checklist-deployment-aplicacao-dotnet.md) |

---

## Sistemas legados

| Sintoma | Documento |
|---|---|
| Sistema legado precisa consumir uma API REST moderna | [`legado-consumindo-api-rest-moderna.md`](sistemas-legados/legado-consumindo-api-rest-moderna.md) |
| Precisamos modernizar sem parar o sistema | [`modernizacao-incremental-strangler.md`](sistemas-legados/modernizacao-incremental-strangler.md) |
| "Como eu faço isso no Core, se no MVC 5 era assim?" | [`mapa-de-versoes-e-equivalencias.md`](aspnet/mapa-de-versoes-e-equivalencias.md) |
| O EF6 está gerando centenas de queries | [`ef6-troubleshooting.md`](acesso-a-dados/entity-framework-6/ef6-troubleshooting.md) |
| Código sem teste que precisa mudar | [`sistemas-legados/`](sistemas-legados/) |

---

## Regra de ouro de qualquer incidente

> **Salve a evidência antes de mitigar.**

A cadeia de bloqueio, a transação aberta, o estado das threads e o conteúdo da memória desaparecem
no instante em que você mata a sessão ou reinicia o processo. Sem a evidência salva, a reunião de
pós-incidente termina em "reiniciamos e melhorou" — o que garante a reincidência.

---

**Criado por Fábio Cerqueira**
