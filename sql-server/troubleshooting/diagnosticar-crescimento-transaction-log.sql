/* ===========================================================================
   NOME       : diagnosticar-crescimento-transaction-log.sql
   OBJETIVO   : Descobrir POR QUE o transaction log de um banco nao esta sendo
                truncado e continua crescendo.

   COMPATIBILIDADE : SQL Server 2012+ (11.x).
                     Azure SQL Database: parcial -- o BLOCO 1 funciona; o
                     conceito de backup de log nao se aplica da mesma forma.
   IMPACTO         : Nenhum. Somente leitura sobre catalogo e DMVs.
   PERMISSOES      : VIEW SERVER STATE e VIEW ANY DEFINITION.
   TEMPO ESTIMADO  : < 3 segundos.

   ATENCAO    : Este script DIAGNOSTICA. Ele nao encolhe nada de proposito.
                Antes de considerar SHRINK, leia
                ../administracao/shrink-quando-nao-usar.md -- encolher o log
                sem corrigir a causa apenas adia o problema e fragmenta VLFs.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

/* ---------------------------------------------------------------------------
   BLOCO 1 - A pergunta central: o que impede o truncamento?
   A coluna log_reuse_wait_desc responde diretamente.
   --------------------------------------------------------------------------- */
SELECT
    banco                 = d.name,
    d.recovery_model_desc,
    d.log_reuse_wait_desc,
    traducao = CASE d.log_reuse_wait_desc
        WHEN 'NOTHING'            THEN 'Nada impede. O log pode ser reutilizado normalmente.'
        WHEN 'CHECKPOINT'         THEN 'Aguardando checkpoint. Normal e transitorio.'
        WHEN 'LOG_BACKUP'         THEN 'FALTA BACKUP DE LOG. Causa mais comum em FULL/BULK_LOGGED.'
        WHEN 'ACTIVE_BACKUP_OR_RESTORE' THEN 'Backup ou restore em andamento. Aguarde terminar.'
        WHEN 'ACTIVE_TRANSACTION' THEN 'TRANSACAO ABERTA segurando o log. Veja o BLOCO 3.'
        WHEN 'DATABASE_MIRRORING' THEN 'Mirroring atrasado ou suspenso.'
        WHEN 'REPLICATION'        THEN 'Replicacao/CDC nao consumiu o log. Verifique o Log Reader Agent.'
        WHEN 'DATABASE_SNAPSHOT_CREATION' THEN 'Criacao de snapshot em andamento.'
        WHEN 'LOG_SCAN'           THEN 'Varredura de log em andamento. Transitorio.'
        WHEN 'AVAILABILITY_REPLICA' THEN 'Replica secundaria de AG atrasada ou indisponivel.'
        WHEN 'OLDEST_PAGE'        THEN 'Pagina mais antiga ainda nao gravada (indirect checkpoint).'
        WHEN 'XTP_CHECKPOINT'     THEN 'Checkpoint de In-Memory OLTP pendente.'
        ELSE 'Consultar documentacao de sys.databases.log_reuse_wait_desc'
    END,
    esta_em_autogrow_ilimitado = CASE
        WHEN EXISTS (SELECT 1 FROM sys.master_files AS mf
                     WHERE mf.database_id = d.database_id
                       AND mf.type_desc = 'LOG'
                       AND mf.max_size = -1)
        THEN 'SIM - o log pode crescer ate encher o disco'
        ELSE 'nao' END
FROM sys.databases AS d
WHERE d.database_id > 4          /* ignora os bancos de sistema */
   OR d.name = 'tempdb'
ORDER BY
    CASE WHEN d.log_reuse_wait_desc NOT IN ('NOTHING', 'CHECKPOINT') THEN 0 ELSE 1 END,
    d.name;


/* ---------------------------------------------------------------------------
   BLOCO 2 - Tamanho e ocupacao dos arquivos de log
   --------------------------------------------------------------------------- */
SELECT
    banco               = DB_NAME(mf.database_id),
    arquivo_logico      = mf.name,
    arquivo_fisico      = mf.physical_name,
    tamanho_mb          = mf.size * 8.0 / 1024,
    crescimento         = CASE WHEN mf.is_percent_growth = 1
                               THEN CAST(mf.growth AS VARCHAR(10)) + ' %'
                               ELSE CAST(mf.growth * 8.0 / 1024 AS VARCHAR(20)) + ' MB' END,
    alerta_crescimento  = CASE
                              WHEN mf.is_percent_growth = 1
                                  THEN 'ATENCAO: crescimento percentual gera autogrow cada vez maior'
                              WHEN mf.growth * 8.0 / 1024 < 64
                                  THEN 'ATENCAO: incremento pequeno gera muitos eventos de autogrow e VLFs'
                              ELSE 'ok' END,
    tamanho_maximo      = CASE WHEN mf.max_size = -1 THEN 'ILIMITADO'
                               WHEN mf.max_size = 268435456 THEN 'ILIMITADO (log)'
                               ELSE CAST(mf.max_size * 8.0 / 1024 AS VARCHAR(20)) + ' MB' END
FROM sys.master_files AS mf
WHERE mf.type_desc = 'LOG'
  AND mf.database_id > 4
ORDER BY mf.size DESC;


/* ---------------------------------------------------------------------------
   BLOCO 3 - Transacao aberta mais antiga por banco
   So faz sentido quando log_reuse_wait_desc = 'ACTIVE_TRANSACTION'.
   --------------------------------------------------------------------------- */
SELECT
    banco             = DB_NAME(dbt.database_id),
    s.session_id,
    idade_minutos     = DATEDIFF(MINUTE, dbt.database_transaction_begin_time, SYSDATETIME()),
    inicio            = dbt.database_transaction_begin_time,
    log_usado_mb      = dbt.database_transaction_log_bytes_used / 1024.0 / 1024.0,
    log_reservado_mb  = dbt.database_transaction_log_bytes_reserved / 1024.0 / 1024.0,
    status_sessao     = s.status,
    login             = s.login_name,
    host              = s.host_name,
    programa          = s.program_name
FROM sys.dm_tran_database_transactions AS dbt
INNER JOIN sys.dm_tran_session_transactions AS tst
        ON tst.transaction_id = dbt.transaction_id
INNER JOIN sys.dm_exec_sessions AS s
        ON s.session_id = tst.session_id
WHERE dbt.database_id > 4
ORDER BY dbt.database_transaction_begin_time ASC;


/* ---------------------------------------------------------------------------
   BLOCO 4 - Ultimo backup de log por banco
   Bancos em FULL/BULK_LOGGED sem backup de log tem o log crescendo por design.
   --------------------------------------------------------------------------- */
SELECT
    banco                   = d.name,
    d.recovery_model_desc,
    ultimo_backup_full      = MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END),
    ultimo_backup_diff      = MAX(CASE WHEN b.type = 'I' THEN b.backup_finish_date END),
    ultimo_backup_log       = MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END),
    horas_desde_backup_log  = DATEDIFF(HOUR,
                                  MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END),
                                  SYSDATETIME()),
    diagnostico = CASE
        WHEN d.recovery_model_desc IN ('FULL', 'BULK_LOGGED')
         AND MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END) IS NULL
            THEN 'CAUSA PROVAVEL: banco em FULL sem NENHUM backup de log'
        WHEN d.recovery_model_desc IN ('FULL', 'BULK_LOGGED')
         AND DATEDIFF(HOUR, MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END), SYSDATETIME()) > 24
            THEN 'CAUSA PROVAVEL: backup de log parado ha mais de 24h'
        WHEN d.recovery_model_desc IN ('FULL', 'BULK_LOGGED')
         AND MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END) IS NULL
            THEN 'ATENCAO: em FULL mas sem backup full -- o banco esta em pseudo-SIMPLE'
        ELSE 'sem indicio de problema de backup'
    END
FROM sys.databases AS d
LEFT JOIN msdb.dbo.backupset AS b
       ON b.database_name = d.name
WHERE d.database_id > 4
GROUP BY d.name, d.recovery_model_desc
ORDER BY d.name;

/* ===========================================================================
   COMO LER O RESULTADO E O QUE FAZER

   log_reuse_wait_desc = 'LOG_BACKUP'
       Banco em FULL ou BULK_LOGGED sem backup de log em dia.
       CORRECAO CORRETA .... criar/corrigir o job de backup de log.
       ERRO COMUM ......... trocar o recovery model para SIMPLE "para resolver".
                            Isso QUEBRA A CADEIA DE BACKUP e elimina a
                            capacidade de restore point-in-time. So faca isso
                            se o negocio realmente aceitar perder tudo desde o
                            ultimo full/diff -- e deixe isso documentado.

   log_reuse_wait_desc = 'ACTIVE_TRANSACTION'
       Veja o BLOCO 3. Nenhum backup de log vai truncar enquanto essa
       transacao estiver aberta. Corrija a aplicacao.

   log_reuse_wait_desc = 'REPLICATION'
       Replicacao ou CDC configurados e nao consumindo o log. Verifique o
       Log Reader Agent. Atencao: CDC deixa este estado mesmo apos remover a
       replicacao, se nao foi desabilitado corretamente.

   log_reuse_wait_desc = 'AVAILABILITY_REPLICA'
       Secundaria de Availability Group atrasada ou fora do ar.

   DEPOIS de corrigir a causa, o log volta a ser reutilizado internamente --
   o arquivo NAO diminui de tamanho sozinho, mas para de crescer. Encolher o
   arquivo e uma decisao separada e raramente necessaria:
   ../administracao/shrink-quando-nao-usar.md
   =========================================================================== */
