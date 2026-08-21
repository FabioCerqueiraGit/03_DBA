# `SHRINK` — quando **não** usar (que é quase sempre)

> `DBCC SHRINKDATABASE` e `DBCC SHRINKFILE` são os comandos mais executados por engano do
> SQL Server. Eles recuperam espaço em disco e, no mesmo movimento, fragmentam todos os
> índices do banco. Este documento explica o mecanismo, para que a decisão seja consciente.

| | |
|---|---|
| **Compatibilidade** | SQL Server 2012+ (11.x) · Azure SQL Database: parcial |
| **Impacto em produção** | **Muito alto.** I/O intenso, bloqueio e fragmentação massiva |
| **Permissões** | `sysadmin` ou `db_owner` |
| **Reversível** | O espaço volta a crescer; a fragmentação exige `REBUILD` para desfazer |

---

## Por que existe tanta confusão

A intuição é razoável: o arquivo está com 200 GB, mas só 100 GB são dados; logo, encolher
deveria ser bom. O erro está em achar que **espaço livre dentro do arquivo é desperdício**.

Espaço livre interno é o que permite ao banco crescer sem disparar um evento de *autogrow*
no meio do expediente. Ele não é sobra: é folga operacional, e ela tem valor.

---

## O que o `SHRINK` realmente faz

O algoritmo é simples e destrutivo para a organização dos dados:

1. pega as páginas do **fim** do arquivo;
2. move cada uma para o primeiro espaço livre que encontrar no **começo**;
3. repete até atingir o tamanho pedido;
4. libera o final do arquivo para o sistema operacional.

O problema está no passo 2: as páginas são movidas **sem qualquer respeito à ordem lógica
dos índices**. Uma página que era a décima de um índice pode acabar fisicamente antes da
primeira.

O resultado é previsível: **fragmentação próxima de 100% em praticamente todos os índices
do banco.** Não é efeito colateral raro — é o comportamento esperado.

### O ciclo destrutivo clássico

```text
1. SHRINK             -> recupera 50 GB, fragmenta tudo
2. "ficou lento"      -> REBUILD de todos os indices
3. REBUILD            -> o arquivo cresce de novo (precisa de espaco de trabalho)
4. "o disco encheu"   -> SHRINK
5. volta ao passo 1
```

Cada volta consome janela de manutenção, gera transaction log, infla o backup diferencial
e não resolve nada. Muitos ambientes rodam esse ciclo há anos, agendado.

---

## Quando NÃO usar

- **Como rotina agendada.** Job semanal de `SHRINK` é uma das piores práticas que existem
  em administração de SQL Server. Se há um no seu ambiente, ele está causando trabalho, não
  evitando.
- **"Para melhorar a performance."** O efeito é exatamente o oposto.
- **Logo após um `DELETE` massivo**, se a tabela vai voltar a crescer. O espaço liberado
  seria reaproveitado de graça.
- **Em `tempdb`, em produção.** Ele volta ao tamanho no próximo restart, e encolher com
  carga ativa pode gerar erro de alocação.
- **Com `DBCC SHRINKDATABASE`, praticamente nunca.** Ele opera no banco inteiro, sem
  controle de qual arquivo. Se precisar mesmo encolher, use `DBCC SHRINKFILE`, arquivo a
  arquivo.
- **No transaction log, antes de descobrir por que ele cresceu.** Veja
  [`../troubleshooting/por-que-o-transaction-log-esta-crescendo.md`](../troubleshooting/por-que-o-transaction-log-esta-crescendo.md).
- **Com `AUTO_SHRINK` ligado.** Essa opção executa o ciclo destrutivo automaticamente, em
  horário imprevisível. Verifique e desligue:

```sql
SELECT name, is_auto_shrink_on
FROM sys.databases
WHERE is_auto_shrink_on = 1;

-- ALTER DATABASE [<BANCO>] SET AUTO_SHRINK OFF;
```

---

## Quando o `SHRINK` é legítimo

Existem casos reais, e todos têm a mesma assinatura: **o arquivo cresceu por um motivo
não recorrente e não voltará a precisar daquele tamanho.**

| Situação | Por que se justifica |
|---|---|
| Arquivamento definitivo de anos de histórico | A tabela não vai recrescer |
| Restore de produção em servidor de desenvolvimento menor | Espaço é restrição real e fragmentação importa pouco ali |
| Log que explodiu por um incidente pontual já corrigido | O tamanho anômalo não se repetirá |
| Migração que deixou uma tabela enorme para trás | Evento único |
| Emergência de disco cheio | Mitigação consciente, com correção depois |

Em todos, a decisão é pontual e vem acompanhada de um plano de reconstrução de índices.

---

## Como fazer, quando for mesmo necessário

```sql
/* 1. Descobrir os arquivos e o espaco livre interno */
USE [<BANCO>];
SELECT
    arquivo        = name,
    tipo           = type_desc,
    tamanho_mb     = size * 8.0 / 1024,
    usado_mb       = FILEPROPERTY(name, 'SpaceUsed') * 8.0 / 1024,
    livre_mb       = (size - FILEPROPERTY(name, 'SpaceUsed')) * 8.0 / 1024
FROM sys.database_files;
```

```sql
/* 2. Encolher em ETAPAS, nunca de uma vez.
      Encolher 200 GB de uma vez pode rodar por horas segurando recursos.
      Fazendo em degraus, cada etapa e curta e interrompivel. */

-- ATENCAO: comandos que ALTERAM. Descomente conscientemente e rode em janela.
-- DBCC SHRINKFILE (N'<ARQUIVO_LOGICO>', 180000);   -- alvo em MB
-- DBCC SHRINKFILE (N'<ARQUIVO_LOGICO>', 160000);
-- DBCC SHRINKFILE (N'<ARQUIVO_LOGICO>', 140000);
```

```sql
/* 3. Deixe FOLGA. Encolher ate o limite garante autogrow amanha.
      Regra pratica: 20% a 25% de espaco livre interno. */
```

```sql
/* 4. RECONSTRUIR OS INDICES depois -- este passo nao e opcional.
      Sem ele, o banco fica fragmentado e lento.
      Faca por tabela, comecando pelas maiores, dentro da janela. */

-- ALTER INDEX ALL ON <ESQUEMA>.<TABELA>
--     REBUILD WITH (ONLINE = OFF, SORT_IN_TEMPDB = ON, FILLFACTOR = 90);
```

```sql
/* 5. Conferir o resultado */
-- Rode ../indexes/analisar-fragmentacao.sql antes e depois.
```

> **Ordem importa.** `SHRINK` depois, `REBUILD` por último. Fazer `REBUILD` antes do
> `SHRINK` é desperdício puro: o `SHRINK` desfragmenta tudo de novo.

---

## `TRUNCATEONLY` — a opção esquecida

```sql
DBCC SHRINKFILE (N'<ARQUIVO_LOGICO>', TRUNCATEONLY);
```

Libera apenas o espaço livre **no final do arquivo**, sem mover página nenhuma.

- **Não fragmenta nada.**
- É muito rápido.
- Só recupera o que já estiver livre no fim — que pode ser pouco, ou nada.

**Sempre tente `TRUNCATEONLY` primeiro.** Se ele resolver, você recuperou espaço com custo
praticamente zero. Aplica-se tanto a arquivos de dados quanto de log.

---

## Alternativas antes de encolher

| Situação | Alternativa melhor |
|---|---|
| Disco cheio | Verificar backups antigos, arquivos `.trn` acumulados, `tempdb` e dumps |
| Tabela histórica enorme | Arquivamento, particionamento, ou compressão de dados (`ROW`/`PAGE`) |
| Índices ocupando demais | Remover duplicados e não utilizados — [`../indexes/`](../indexes/) |
| Log gigante | Corrigir a causa — [`../troubleshooting/por-que-o-transaction-log-esta-crescendo.md`](../troubleshooting/por-que-o-transaction-log-esta-crescendo.md) |
| Banco crescendo rápido | Entender o crescimento — [`../espaco-e-crescimento/tamanho-das-tabelas.sql`](../espaco-e-crescimento/tamanho-das-tabelas.sql) |

A compressão de dados merece destaque: em muitas tabelas históricas, `PAGE` compression
reduz o espaço de forma expressiva **e** costuma reduzir I/O de leitura, porque cabem mais
linhas por página. Verifique a disponibilidade na sua edição e versão antes de planejar.

---

## Resumo em uma linha

> Espaço livre dentro do arquivo não é problema. `SHRINK` como rotina, sim.

## Referências

- [`DBCC SHRINKFILE`](https://learn.microsoft.com/pt-br/sql/t-sql/database-console-commands/dbcc-shrinkfile-transact-sql)
- [`DBCC SHRINKDATABASE`](https://learn.microsoft.com/pt-br/sql/t-sql/database-console-commands/dbcc-shrinkdatabase-transact-sql)
- [Compressão de dados](https://learn.microsoft.com/pt-br/sql/relational-databases/data-compression/data-compression)

---

**Criado por Fábio Cerqueira**
