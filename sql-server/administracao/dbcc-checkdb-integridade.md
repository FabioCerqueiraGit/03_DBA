# `DBCC CHECKDB` — verificar integridade antes que ela cobre

> Corrupção de banco não avisa. Ela fica quieta por semanas, entra nos backups, e só
> aparece quando alguém tenta ler a página errada. `DBCC CHECKDB` é o único jeito de
> descobrir antes.

| | |
|---|---|
| **Compatibilidade** | SQL Server 2012+ (11.x) · Azure SQL Database: gerenciado pelo serviço |
| **Impacto** | **Alto.** I/O intenso, CPU e uso de `tempdb`. Rode em janela |
| **Permissões** | `sysadmin` ou `db_owner` |

---

## Problema

Páginas corrompidas por falha de disco, de controladora, de driver ou de firmware. Os
sintomas típicos:

```text
Msg 824 — SQL Server detected a logical consistency-based I/O error
Msg 823 — The operating system returned error ... to SQL Server
Msg 825 — A read of the file succeeded after failing N time(s)
```

O erro **825** é o mais importante e o mais ignorado: significa que a leitura **só deu
certo depois de repetir**. É um aviso de que o subsistema de armazenamento está morrendo,
com sorte antes de a corrupção se instalar. Monitore o ERRORLOG procurando por ele.

---

## O comando

```sql
/* Verificacao completa. Rode em janela de manutencao. */
DBCC CHECKDB (N'<BANCO>') WITH NO_INFOMSGS, ALL_ERRORMSGS;
```

| Opção | Efeito |
|---|---|
| `NO_INFOMSGS` | Omite as mensagens informativas; sobra o que interessa |
| `ALL_ERRORMSGS` | Lista todos os erros, não só os primeiros |
| `PHYSICAL_ONLY` | Verificação mais rápida, só consistência física |
| `DATA_PURITY` | Valida valores fora do intervalo válido do tipo de dado |
| `EXTENDED_LOGICAL_CHECKS` | Verificações adicionais (views indexadas, índices XML/espaciais) — bem mais caro |

```sql
/* Alternativa para bases muito grandes, quando a janela nao comporta a
   verificacao completa. Detecta a maior parte da corrupcao de hardware. */
DBCC CHECKDB (N'<BANCO>') WITH PHYSICAL_ONLY, NO_INFOMSGS;
```

> `PHYSICAL_ONLY` **não substitui** a verificação completa. Um esquema comum é
> `PHYSICAL_ONLY` com frequência alta e o `CHECKDB` completo no fim de semana.

---

## Quando rodar

- **Periodicamente**, em janela de manutenção. Semanal é um bom ponto de partida.
- **No banco restaurado em servidor de teste** — a melhor prática que quase ninguém adota:
  valida a integridade **e** o backup ao mesmo tempo, sem consumir I/O da produção.
- Depois de falha de hardware, queda de energia ou erro de I/O no ERRORLOG.
- Antes de uma migração ou upgrade importante.

## Quando NÃO rodar

- **No horário de pico.** O consumo de I/O e `tempdb` é relevante e vai aparecer como
  lentidão generalizada.
- **Em vários bancos grandes ao mesmo tempo**, na mesma instância.
- **Sem espaço em `tempdb`.** `CHECKDB` cria um snapshot interno e usa `tempdb`; verifique
  a folga antes.

---

## Se encontrar corrupção

**A primeira regra: não corra para `REPAIR_ALLOW_DATA_LOSS`.** O nome descreve exatamente
o que ele faz.

### Passo 1 — Preservar a evidência

```sql
/* Guarde a saida completa do CHECKDB em arquivo, com data e hora.
   Ela identifica o objeto, a pagina e o tipo de erro. */
```

### Passo 2 — Identificar a extensão do dano

A saída informa a tabela e o índice afetados. Corrupção restrita a um **índice não
clusterizado** é o melhor cenário possível: basta reconstruir o índice, porque os dados
estão íntegros na tabela.

```sql
/* Corrupcao apenas em indice nao clusterizado: recriar resolve, sem perda */
ALTER INDEX [<INDICE>] ON <ESQUEMA>.<TABELA> REBUILD;
```

### Passo 3 — Restaurar do backup (o caminho correto)

Se a corrupção atinge dados, a solução **certa** é restaurar. Em muitos casos dá para
restaurar apenas as páginas afetadas, sem derrubar o banco inteiro:

```sql
/* Restore de pagina: exige recovery model FULL e cadeia de log intacta */
RESTORE DATABASE [<BANCO>]
    PAGE = '<file_id>:<page_id>'
FROM DISK = N'<CAMINHO>\<BANCO>_FULL.bak'
WITH NORECOVERY;

/* Em seguida, aplicar os logs subsequentes e, por fim, WITH RECOVERY. */
```

Esta é uma das razões mais concretas para manter `FULL` e backup de log em dia.

### Passo 4 — `REPAIR_ALLOW_DATA_LOSS` (último recurso)

```sql
/* ULTIMO RECURSO. Exige o banco em SINGLE_USER e APAGA DADOS. */
-- ALTER DATABASE [<BANCO>] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
-- DBCC CHECKDB (N'<BANCO>', REPAIR_ALLOW_DATA_LOSS);
-- ALTER DATABASE [<BANCO>] SET MULTI_USER;
```

O que ele faz de fato: **desaloca as páginas corrompidas**. As linhas que estavam nelas
deixam de existir. Não há aviso de quais linhas foram perdidas, e a integridade
referencial pode ser violada no processo.

Use apenas quando: não existe backup utilizável, **e** o negócio aceita perda
indeterminada de dados, **e** essa decisão está registrada por escrito. Antes de executar,
tire um backup do banco corrompido — ele é a última cópia do que ainda existe.

### Passo 5 — Achar a causa

Corrupção é quase sempre problema de **infraestrutura**: disco, controladora, driver,
firmware, cache de escrita sem proteção contra queda de energia, antivírus escaneando
arquivos de banco. Reparar sem investigar garante a reincidência.

Suspeitos frequentes:

- antivírus sem exclusão para `.mdf`, `.ndf`, `.ldf` e `.bak`;
- controladora com write cache sem bateria ou capacitor;
- driver de storage desatualizado;
- storage de rede sem garantia de escrita ordenada.

---

## Verificar o último `CHECKDB` bem-sucedido

```sql
/* Le a data do ultimo CHECKDB limpo, gravada no boot page do banco.
   Rode no contexto do banco. */
DBCC DBINFO() WITH TABLERESULTS;
-- Procure a linha dbi_dbccLastKnownGood
```

Se a data for antiga, ninguém está verificando — e uma corrupção pode já estar dentro de
todos os backups.

---

## Configurações que ajudam a prevenir

```sql
/* PAGE_VERIFY CHECKSUM: o SQL Server valida um checksum a cada leitura.
   Bancos criados em versoes muito antigas podem estar com TORN_PAGE_DETECTION
   ou NONE herdado. */
SELECT name, page_verify_option_desc
FROM sys.databases
WHERE page_verify_option_desc <> 'CHECKSUM';

-- ALTER DATABASE [<BANCO>] SET PAGE_VERIFY CHECKSUM;
```

Essa é uma das verificações mais baratas e mais esquecidas em bancos legados.

---

## Checklist

- [ ] `DBCC CHECKDB` roda periodicamente e o resultado é conferido por alguém.
- [ ] `PAGE_VERIFY` está em `CHECKSUM` em todos os bancos.
- [ ] Backups são feitos `WITH CHECKSUM`.
- [ ] O ERRORLOG é monitorado para os erros 823, 824 e 825.
- [ ] Existe alerta quando o `CHECKDB` falha ou deixa de rodar.
- [ ] Antivírus tem exclusão para os arquivos de banco e de backup.

## Referências

- [`DBCC CHECKDB`](https://learn.microsoft.com/pt-br/sql/t-sql/database-console-commands/dbcc-checkdb-transact-sql)
- [Restaurar páginas](https://learn.microsoft.com/pt-br/sql/relational-databases/backup-restore/restore-pages-sql-server)
- [`ALTER DATABASE SET` — `PAGE_VERIFY`](https://learn.microsoft.com/pt-br/sql/t-sql/statements/alter-database-transact-sql-set-options)

---

**Criado por Fábio Cerqueira**
