# Como contribuir

Este repositório é uma caixa de ferramentas operacional. O critério de aceitação de
qualquer conteúdo novo é simples e único:

> **Isso ajudaria alguém a resolver um problema real, sob pressão, em produção?**

Se a resposta for "é um bom exemplo didático", o conteúdo provavelmente não pertence aqui.
Se for "eu já precisei disso e não achei em lugar nenhum", pertence.

---

## Antes de abrir um Pull Request

1. **Procure duplicidade.** Pressione <kbd>t</kbd> na página do repositório e busque pelo
   tema. Melhorar um documento existente vale mais do que criar um parecido.
2. **Escolha o template certo** em [`templates/`](templates/) e siga a estrutura dele.
3. **Teste o que você está enviando.** Script T-SQL precisa ter rodado em pelo menos uma
   versão real do SQL Server. Código C# precisa compilar.
4. **Registre a versão em que testou.** "Funciona" sem versão não é informação.

---

## Padrão obrigatório dos documentos

Todo documento de solução é **autocontido**: quem abre ele consegue resolver o problema sem
ler outros três antes. Use esta espinha dorsal — omita as seções que não se aplicarem, mas
não invente conteúdo para preenchê-las:

```markdown
# Titulo -- o problema, nao a tecnologia

> Resumo de uma linha: o que este documento resolve.

| | |
|---|---|
| **Compatibilidade** | SQL Server 2016+ / .NET Framework 4.6.2+ e .NET 8+ |
| **Impacto em producao** | Nenhum (somente leitura) / Baixo / Alto -- requer janela |
| **Permissoes** | VIEW SERVER STATE |

## Problema
## Quando utilizar
## Quando NAO utilizar
## Pre-requisitos
## Solucao
## Como utilizar
## Explicacao
## Exemplo
## Cuidados
## Performance
## Seguranca
## Compatibilidade
## Troubleshooting
## Referencias

---

**Criado por Fabio Cerqueira**
```

A seção **"Quando NÃO utilizar"** não é opcional e não pode ser preenchida com "sempre pode
usar". Toda ferramenta tem contraindicação; se você não encontrou a da sua, provavelmente
ainda não entendeu a ferramenta.

Documentos que descrevem comandos perigosos (`DBCC SHRINKFILE`, `KILL`,
`ALTER INDEX ... REBUILD` em tabela grande, `WITH (NOLOCK)`) devem explicar o dano possível
**antes** de mostrar a sintaxe.

---

## Padrão obrigatório dos scripts T-SQL

Todo arquivo `.sql` começa com este cabeçalho:

```sql
/* ===========================================================================
   NOME       : encontrar-indices-nao-utilizados.sql
   OBJETIVO   : Listar indices que consomem escrita e manutencao sem servir
                nenhuma leitura desde o ultimo restart da instancia.

   COMPATIBILIDADE : SQL Server 2012+ (11.x). Azure SQL Database: sim, com
                     escopo de banco.
   IMPACTO         : Nenhum. Somente leitura sobre DMVs.
   PERMISSOES      : VIEW SERVER STATE (instancia) ou VIEW DATABASE STATE.
   TEMPO ESTIMADO  : < 2 segundos.

   ATENCAO    : As estatisticas de uso zeram no restart da instancia. Nao
                conclua nada com uptime menor que um ciclo completo de
                negocio.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */
```

E termina com um bloco **`COMO LER O RESULTADO`**, explicando o que cada coluna significa
e o que fazer com ela.

Regras adicionais:

- Comentários explicativos em português, **sem acentuação** dentro de arquivos `.sql`
  (evita problema de collation e de editor em servidores antigos).
- Nomes de objeto, palavras-chave e sintaxe permanecem em T-SQL padrão.
- Scripts que **alteram** qualquer coisa vêm comentados por padrão, precedidos de um bloco
  `ATENCAO` explicando o efeito e como reverter.
- Deixe explícito quando o script tem escopo de banco (exige `USE [<BANCO>]`).
- Não use `SELECT *` em script de diagnóstico: nomeie as colunas, para que a saída seja
  estável entre versões.
- Prefira `SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED` em scripts de diagnóstico de
  incidente — é um dos poucos usos legítimos de leitura suja, porque o script não pode
  ficar bloqueado pelo problema que investiga.

---

## Padrão obrigatório do código C#

- Compilável e completo o suficiente para ser colado em um projeto real.
- Nada de `catch (Exception) { }` silencioso em exemplo — se o exemplo precisa engolir
  exceção para caber, o exemplo está errado.
- `IDisposable` sempre com `using`.
- `async` até o topo: nada de `.Result` ou `.Wait()`, exceto quando o próprio documento
  estiver explicando por que aquilo é um erro.
- `CancellationToken` recebido e propagado em todo método de I/O.
- Quando a API mudou entre plataformas, mostre as duas versões:

```csharp
// .NET Framework 4.6.2+
// ...

// .NET 8+ / .NET 10
// ...
```

- Indique o pacote NuGet e a versão mínima quando o código depender de um.

---

## Idioma

**Toda a documentação em português do Brasil.** Isso inclui títulos, descrições,
explicações, tabelas, checklists e textos de navegação.

**Código permanece na linguagem original.** Não traduza C#, T-SQL, PowerShell, Bash, YAML,
JSON, XML, nomes de classe, métodos, propriedades, namespaces, APIs, pacotes ou
tecnologias. `ShouldHandle` continua `ShouldHandle`. `Application Pool` continua
`Application Pool`.

---

## Nomes de arquivo

Minúsculas, sem acento, separadas por hífen, descrevendo a **ação** ou o **problema**:

```text
OK    encontrar-sessoes-bloqueadoras.sql
OK    por-que-o-transaction-log-esta-crescendo.md
OK    http-503-service-unavailable.md

NAO   script1.sql
NAO   teste.sql
NAO   Query Final (2).sql
NAO   solucao.md
```

---

## Segurança — regra inegociável

Não envie, em nenhuma hipótese:

- senha real, mesmo de ambiente de desenvolvimento;
- connection string apontando para servidor real;
- token, API key, client secret, connection string de storage;
- certificado privado (`.pfx`, `.p12`, `.key`, `.pem`);
- nome de servidor, IP interno, nome de banco ou nome de cliente reais;
- dump de dados de produção, ainda que "só um exemplinho".

Use placeholders explícitos:

```text
Server=<SERVIDOR>;Database=<BANCO>;User Id=<USUARIO>;Password=<SENHA>;
https://<HOST-DA-API>/v1/pedidos
```

O `.gitignore` já bloqueia os formatos mais comuns de segredo, mas ele é a segunda linha de
defesa, não a primeira. **A primeira é ler o próprio diff antes do commit.**

Se um segredo real vazar em um commit: considere-o comprometido e **rotacione-o**
imediatamente. Remover o arquivo em um commit posterior não resolve — o valor continua no
histórico do Git.

---

## Compatibilidade

Nunca apresente funcionalidade moderna como universal.

- **SQL Server**: declare a versão mínima. Se usar DMV, Query Store ou sintaxe introduzida
  em versão específica, diga qual. Ofereça alternativa para versões anteriores quando
  existir.
- **.NET**: diferencie .NET Framework de .NET Core/.NET 5+. Quando houver diferença
  relevante de comportamento, apresente na ordem **Legado → Intermediário → Moderno**.
- Não escreva "funciona em qualquer versão" sem ter verificado.

---

## Onde colocar o arquivo novo

| O conteúdo é... | Pasta |
|---|---|
| Script que você roda **durante** um incidente de banco | `sql-server/troubleshooting/` |
| Script que mostra o estado atual da instância | `sql-server/monitoramento/` |
| Análise de query, plano, estatística, CPU, I/O | `sql-server/performance/` |
| Qualquer coisa sobre índices | `sql-server/indexes/` |
| Tamanho e crescimento de tabela, índice ou arquivo | `sql-server/espaco-e-crescimento/` |
| Backup, restore, DBCC, permissões, configuração | `sql-server/administracao/` |
| Armadilha de linguagem ou runtime .NET | `dotnet/<subtema>/` |
| ADO.NET, Dapper, EF Core, EF6 | `acesso-a-dados/<tecnologia>/` |
| Consumo ou exposição de API, resiliência, autenticação | `api-integracao/<subtema>/` |
| Erro de IIS, Application Pool, `web.config` | `iis/troubleshooting/` |
| Estratégia de manutenção ou modernização de legado | `sistemas-legados/` |
| Lista de verificação operacional | `checklists/` |

Depois de criar o arquivo, **adicione o link nos dois índices**:
[`INDICE-POR-SINTOMA.md`](INDICE-POR-SINTOMA.md) e
[`INDICE-POR-TECNOLOGIA.md`](INDICE-POR-TECNOLOGIA.md). Conteúdo que não está indexado não
é encontrado às três da manhã, e portanto não existe.

---

## Mensagens de commit

Formato: `<area>: <o que mudou>`

```text
sql-server: adiciona script de arvore de bloqueio hierarquica
dotnet: corrige exemplo de CancellationToken em HttpClient
docs: atualiza indice por sintoma com secao de tempdb
fix: corrige link quebrado no README de acesso-a-dados
```

Um commit por assunto. Commit que mexe em oito áreas ao mesmo tempo é impossível de revisar
e impossível de reverter.

---

## Checklist final

Antes de abrir o Pull Request:

- [ ] Usei o template correspondente ao tipo de conteúdo.
- [ ] O documento tem a seção "Quando NÃO utilizar" preenchida de verdade.
- [ ] Declarei compatibilidade de versão (SQL Server e/ou .NET).
- [ ] Declarei o impacto em produção do que estou propondo.
- [ ] Script T-SQL tem o cabeçalho padronizado e o bloco "COMO LER O RESULTADO".
- [ ] Testei em pelo menos uma versão real e registrei qual.
- [ ] Documentação em português; código na linguagem original.
- [ ] Nome de arquivo descritivo, minúsculo, sem acento, com hífen.
- [ ] **Reli o diff inteiro procurando segredo, nome de servidor ou dado real.**
- [ ] Adicionei o link nos dois índices.
- [ ] Assinatura `**Criado por Fábio Cerqueira**` ao final do documento Markdown.
- [ ] Não atribuí autoria a nenhuma ferramenta de IA.

---

**Criado por Fábio Cerqueira**
