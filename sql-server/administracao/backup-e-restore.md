# Backup e restore — o que importa de verdade

> Backup não testado não é backup: é esperança com nome técnico. Este documento cobre a
> estratégia, os comandos e o roteiro de restore — na ordem em que você vai precisar deles.

| | |
|---|---|
| **Compatibilidade** | SQL Server 2012+ (11.x) · Azure SQL Database gerencia backup de forma própria |
| **Impacto** | Backup: I/O relevante. Restore: **destrutivo no destino** |
| **Permissões** | `db_backupoperator` para backup; `dbcreator`/`sysadmin` para restore |

---

## As duas perguntas que definem tudo

Antes de qualquer comando, duas respostas do negócio — não da TI:

| Sigla | Pergunta | Define |
|---|---|---|
| **RPO** *(Recovery Point Objective)* | Quantos minutos de transação a empresa aceita perder? | A **frequência** do backup de log |
| **RTO** *(Recovery Time Objective)* | Quanto tempo o sistema pode ficar fora enquanto restaura? | A **estratégia** (full, diferencial, filegroup) |

Sem esses dois números, qualquer plano de backup é chute. Com eles, a estratégia se deduz
quase sozinha: RPO de 15 minutos significa backup de log a cada 15 minutos, e ponto.

---

## Recovery model — a decisão que vem antes

| Modelo | Backup de log | Restore point-in-time | Use quando |
|---|---|---|---|
| `SIMPLE` | **Não existe** | **Não** | Desenvolvimento, staging, DW recarregável — perder tudo desde o último full é aceitável |
| `FULL` | Obrigatório | **Sim** | Praticamente todo sistema transacional |
| `BULK_LOGGED` | Sim | Parcial | Janela específica de carga em massa, alternando com `FULL` |

```sql
SELECT name, recovery_model_desc, log_reuse_wait_desc
FROM sys.databases
WHERE database_id > 4;
```

### As duas armadilhas

**1. `FULL` sem backup de log.** O log cresce até encher o disco, porque o SQL Server está
guardando tudo — exatamente como você mandou. Ver
[`../troubleshooting/por-que-o-transaction-log-esta-crescendo.md`](../troubleshooting/por-que-o-transaction-log-esta-crescendo.md).

**2. `FULL` sem nenhum backup full.** O banco fica em *pseudo-SIMPLE*: está marcado como
`FULL`, mas se comporta como `SIMPLE` até o primeiro full ser tirado. A proteção que você
acha que tem, não tem.

**3. Trocar para `SIMPLE` para "resolver" o log cheio.** Quebra a cadeia de backup e
elimina o restore point-in-time, em silêncio. É uma decisão de negócio, não um atalho.

---

## Os três tipos de backup

### Full

```sql
BACKUP DATABASE [<BANCO>]
TO DISK = N'<CAMINHO>\<BANCO>_FULL_<AAAAMMDD_HHMM>.bak'
WITH
    COMPRESSION,       /* menos I/O e menos espaco; disponivel conforme a edicao */
    CHECKSUM,          /* valida as paginas durante a gravacao */
    STATS = 10,
    INIT,              /* sobrescreve o conteudo do arquivo de destino */
    FORMAT;
```

Contem tudo o que é preciso para restaurar o banco naquele ponto. **Não quebra a cadeia de
log** — tirar um full extra a qualquer momento é seguro.

### Diferencial

```sql
BACKUP DATABASE [<BANCO>]
TO DISK = N'<CAMINHO>\<BANCO>_DIFF_<AAAAMMDD_HHMM>.bak'
WITH DIFFERENTIAL, COMPRESSION, CHECKSUM, STATS = 10;
```

Contém tudo que mudou **desde o último full**. Reduz o RTO: em vez de restaurar full mais
centenas de logs, restaura-se full + último diferencial + poucos logs.

> Detalhe que derruba planos de restore: um diferencial depende do full **específico** que
> o precedeu. Se alguém tirar um full avulso — uma ferramenta de backup do servidor, por
> exemplo — os diferenciais seguintes passam a se basear nele. Para evitar isso, existe
> `WITH COPY_ONLY`, que tira um full **sem** redefinir a base dos diferenciais.

```sql
/* Backup avulso, para levar a um ambiente de teste, sem afetar a cadeia */
BACKUP DATABASE [<BANCO>]
TO DISK = N'<CAMINHO>\<BANCO>_COPIA.bak'
WITH COPY_ONLY, COMPRESSION, CHECKSUM;
```

### Transaction log

```sql
BACKUP LOG [<BANCO>]
TO DISK = N'<CAMINHO>\<BANCO>_LOG_<AAAAMMDD_HHMM>.trn'
WITH COMPRESSION, CHECKSUM, STATS = 10;
```

Contém as transações desde o backup de log anterior. É o único que permite restore
point-in-time — e o único que libera espaço interno do log para reutilização.

A **cadeia de log** é a sequência ininterrupta desses backups. Se um arquivo se perder,
não é possível restaurar além dele.

---

## Uma estratégia típica

```text
Domingo 02h00  ....  FULL
Seg-Sab 02h00  ....  DIFERENCIAL
Todo dia, 15/15 min  LOG
```

Com isso: RPO de 15 minutos; restore = 1 full + 1 diferencial + no máximo 96 logs.

Ajuste a partir dos seus números: RPO de 5 minutos exige log de 5 em 5; RTO curto pode
pedir diferencial mais frequente.

### Opções que valem sempre

| Opção | Por quê |
|---|---|
| `CHECKSUM` | Valida as páginas durante a gravação. Backup de página corrompida é pior que backup nenhum, porque dá falsa segurança |
| `COMPRESSION` | Menos espaço e menos I/O; costuma **reduzir** o tempo de backup. Verifique a disponibilidade na sua edição |
| `STATS = 10` | Progresso a cada 10%, útil em operação longa |
| `INIT` / `FORMAT` | Evita empilhar vários backups no mesmo arquivo por engano |

---

## Restore — o roteiro

**A ordem é obrigatória** e o `NORECOVERY` é a parte que mais se erra.

```sql
/* 1. FULL, mantendo o banco em recuperacao para receber os proximos */
RESTORE DATABASE [<BANCO_DESTINO>]
FROM DISK = N'<CAMINHO>\<BANCO>_FULL.bak'
WITH NORECOVERY,
     MOVE N'<ARQUIVO_DADOS_LOGICO>' TO N'<CAMINHO_DESTINO>\<BANCO>.mdf',
     MOVE N'<ARQUIVO_LOG_LOGICO>'   TO N'<CAMINHO_DESTINO>\<BANCO>.ldf',
     STATS = 10;

/* 2. O ULTIMO diferencial (nao todos: apenas o mais recente) */
RESTORE DATABASE [<BANCO_DESTINO>]
FROM DISK = N'<CAMINHO>\<BANCO>_DIFF.bak'
WITH NORECOVERY, STATS = 10;

/* 3. TODOS os logs posteriores, em ordem cronologica */
RESTORE LOG [<BANCO_DESTINO>]
FROM DISK = N'<CAMINHO>\<BANCO>_LOG_001.trn'
WITH NORECOVERY;
-- ... repetir para cada arquivo de log, na ordem ...

/* 4. O ULTIMO comando abre o banco. So aqui usa-se RECOVERY. */
RESTORE LOG [<BANCO_DESTINO>]
FROM DISK = N'<CAMINHO>\<BANCO>_LOG_999.trn'
WITH RECOVERY;
```

### Restore para um momento específico

```sql
/* Restaurar ate um instante -- util quando alguem apagou dados as 14h37 */
RESTORE LOG [<BANCO_DESTINO>]
FROM DISK = N'<CAMINHO>\<BANCO>_LOG_042.trn'
WITH STOPAT = N'2026-08-20T14:36:00', RECOVERY;
```

### Antes de restaurar por cima de um banco existente

```sql
/* Tirar um backup do log ATUAL (tail-log) antes de sobrescrever.
   Sem isso, tudo desde o ultimo backup de log e perdido definitivamente. */
BACKUP LOG [<BANCO>]
TO DISK = N'<CAMINHO>\<BANCO>_TAIL.trn'
WITH NORECOVERY;
```

### Descobrir o que há dentro de um arquivo

```sql
/* Conteudo e nomes logicos dos arquivos -- necessarios para o MOVE */
RESTORE FILELISTONLY FROM DISK = N'<CAMINHO>\<BANCO>_FULL.bak';

/* Cabecalho: tipo do backup, data, versao de origem, LSNs */
RESTORE HEADERONLY  FROM DISK = N'<CAMINHO>\<BANCO>_FULL.bak';

/* Verificar integridade SEM restaurar */
RESTORE VERIFYONLY  FROM DISK = N'<CAMINHO>\<BANCO>_FULL.bak' WITH CHECKSUM;
```

---

## Consultar o histórico de backup

```sql
SELECT TOP (50)
    banco        = bs.database_name,
    tipo         = CASE bs.type
                       WHEN 'D' THEN 'FULL'
                       WHEN 'I' THEN 'DIFERENCIAL'
                       WHEN 'L' THEN 'LOG'
                       WHEN 'F' THEN 'FILE/FILEGROUP'
                       WHEN 'G' THEN 'DIFF DE ARQUIVO'
                       WHEN 'P' THEN 'PARCIAL'
                       ELSE bs.type END,
    inicio       = bs.backup_start_date,
    fim          = bs.backup_finish_date,
    duracao_min  = DATEDIFF(MINUTE, bs.backup_start_date, bs.backup_finish_date),
    tamanho_gb   = CAST(bs.backup_size / 1073741824.0 AS DECIMAL(18,2)),
    comprimido_gb = CAST(bs.compressed_backup_size / 1073741824.0 AS DECIMAL(18,2)),
    copy_only    = bs.is_copy_only,
    destino      = bmf.physical_device_name,
    usuario      = bs.user_name
FROM msdb.dbo.backupset AS bs
INNER JOIN msdb.dbo.backupmediafamily AS bmf
        ON bmf.media_set_id = bs.media_set_id
ORDER BY bs.backup_start_date DESC;
```

```sql
/* Bancos SEM backup recente -- o alerta que salva empregos */
SELECT
    banco               = d.name,
    d.recovery_model_desc,
    ultimo_full         = MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END),
    ultimo_diff         = MAX(CASE WHEN b.type = 'I' THEN b.backup_finish_date END),
    ultimo_log          = MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END),
    dias_sem_full       = DATEDIFF(DAY,
                              MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END),
                              SYSDATETIME()),
    alerta = CASE
        WHEN MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END) IS NULL
            THEN 'CRITICO: NENHUM BACKUP FULL REGISTRADO'
        WHEN DATEDIFF(DAY, MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END),
                      SYSDATETIME()) > 7
            THEN 'CRITICO: full com mais de 7 dias'
        WHEN d.recovery_model_desc = 'FULL'
         AND (MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END) IS NULL
              OR DATEDIFF(HOUR, MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END),
                          SYSDATETIME()) > 24)
            THEN 'ATENCAO: banco em FULL sem backup de log em dia'
        ELSE 'ok'
    END
FROM sys.databases AS d
LEFT JOIN msdb.dbo.backupset AS b
       ON b.database_name = d.name
WHERE d.database_id > 4
  AND d.state_desc = 'ONLINE'
GROUP BY d.name, d.recovery_model_desc
ORDER BY alerta, d.name;
```

---

## Testar o restore — a parte que ninguém faz

Um backup só está comprovadamente bom depois de restaurado. `RESTORE VERIFYONLY` verifica
a mídia, **não** garante que o banco vai subir e que os dados estão consistentes.

Uma rotina mínima de confiança:

1. restaurar o backup em um servidor de teste, com outro nome;
2. rodar `DBCC CHECKDB` no banco restaurado — assim você valida a integridade **sem**
   consumir I/O da produção;
3. conferir alguns números de negócio (contagem de pedidos do dia, saldo total);
4. registrar a data do último teste bem-sucedido.

Se o último teste de restore for de "algum momento do ano passado", o plano de recuperação
é uma hipótese.

---

## Erros que aparecem no pior momento

| Erro | Causa | Solução |
|---|---|---|
| `The backup set holds a backup of a database other than the existing database.` | Restaurando por cima de outro banco | Use `WITH REPLACE` **conscientemente**, ou restaure com outro nome |
| `The file ... cannot be overwritten. It is being used by database ...` | Os caminhos físicos já pertencem a outro banco | Use `MOVE` para apontar caminhos livres |
| `The log in this backup set begins at LSN ..., which is too recent` | Faltou um backup de log da sequência | Restaure os logs na ordem correta, sem pular |
| `Database ... is in restoring state` | Faltou o último `WITH RECOVERY` | `RESTORE DATABASE [<BANCO>] WITH RECOVERY;` |
| `Media family on device is incorrectly formed` | Arquivo corrompido ou incompleto | Use outro backup. Reforce `CHECKSUM` daqui em diante |
| Restore falha citando versão | Backup de versão mais nova | Não há downgrade de backup. Restaure em versão igual ou superior |

> **Sobre logins órfãos.** Depois de restaurar em outro servidor, os usuários do banco
> podem ficar sem login correspondente na instância. É o clássico "restaurei e a aplicação
> não conecta". Verifique em `sys.database_principals` contra `sys.server_principals` e
> corrija o mapeamento com `ALTER USER ... WITH LOGIN = ...`.

---

## Checklist

- [ ] RPO e RTO acordados **com o negócio** e documentados.
- [ ] Recovery model coerente com o RPO.
- [ ] Backup full periódico, com `CHECKSUM`.
- [ ] Backup de log na frequência do RPO (se `FULL`).
- [ ] Backups gravados **fora** do servidor de banco.
- [ ] Cópia fora do site principal.
- [ ] Retenção definida e limpeza automática funcionando.
- [ ] Alerta quando um backup falha — e alerta quando ele simplesmente **não roda**.
- [ ] Restore testado, com data do último teste registrada.
- [ ] Procedimento de restore escrito, legível por quem estiver de plantão.

## Referências

- [Backup e restauração](https://learn.microsoft.com/pt-br/sql/relational-databases/backup-restore/back-up-and-restore-of-sql-server-databases)
- [`BACKUP`](https://learn.microsoft.com/pt-br/sql/t-sql/statements/backup-transact-sql)
- [`RESTORE`](https://learn.microsoft.com/pt-br/sql/t-sql/statements/restore-statements-transact-sql)
- [Modelos de recuperação](https://learn.microsoft.com/pt-br/sql/relational-databases/backup-restore/recovery-models-sql-server)

---

**Criado por Fábio Cerqueira**
