/* ===========================================================================
   NOME       : diagnostico-rapido-30-segundos.sql
   OBJETIVO   : Triagem inicial de um incidente de lentidao. Responde, em uma
                unica execucao: quem esta rodando, quem esta bloqueando quem,
                o que a instancia esta esperando, como esta o tempdb e como
                esta a memoria.

   COMPATIBILIDADE : SQL Server 2012+ (11.x).
                     Azure SQL Database: os blocos 1, 5 e 6 sao de instancia e
                     podem nao retornar dados; os demais funcionam.
   IMPACTO         : Nenhum. Somente leitura sobre DMVs.
   PERMISSOES      : VIEW SERVER STATE.
   TEMPO ESTIMADO  : < 5 segundos.

   ATENCAO    : As DMVs de estatistica acumulada zeram no restart da
                instancia. Confira o uptime no bloco 1 antes de tirar
                conclusoes dos blocos 4 e 6.

   COMO USAR  : Execute o script inteiro e SALVE A SAIDA EM ARQUIVO antes de
                tomar qualquer acao corretiva. A cadeia de bloqueio desaparece
                em segundos e nao pode ser reconstruida depois.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

/* Leitura suja e proposital: durante um incidente o script de diagnostico nao
   pode ficar bloqueado pelo proprio problema que investiga. Este e um dos
   poucos usos legitimos de READ UNCOMMITTED. */
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;


/* ---------------------------------------------------------------------------
   BLOCO 1 - Identidade da instancia e uptime
   Uptime baixo invalida a leitura dos blocos de estatistica acumulada.
   --------------------------------------------------------------------------- */
SELECT
    bloco               = '1 - Instancia',
    servidor            = CONVERT(sysname, SERVERPROPERTY('MachineName')),
    instancia           = CONVERT(sysname, SERVERPROPERTY('ServerName')),
    versao_produto      = CONVERT(sysname, SERVERPROPERTY('ProductVersion')),
    nivel_produto       = CONVERT(sysname, SERVERPROPERTY('ProductLevel')),
    edicao              = CONVERT(sysname, SERVERPROPERTY('Edition')),
    inicio_da_instancia = si.sqlserver_start_time,
    uptime_horas        = DATEDIFF(HOUR, si.sqlserver_start_time, SYSDATETIME()),
    cpus_visiveis       = si.cpu_count
FROM sys.dm_os_sys_info AS si;


/* ---------------------------------------------------------------------------
   BLOCO 2 - O que esta executando agora
   Ordenado pela duracao: o que esta ha mais tempo em execucao aparece primeiro.
   --------------------------------------------------------------------------- */
SELECT
    bloco             = '2 - Executando agora',
    r.session_id,
    r.blocking_session_id,
    r.status,
    r.command,
    duracao_seg       = r.total_elapsed_time / 1000,
    cpu_seg           = r.cpu_time / 1000,
    r.logical_reads,
    r.reads,
    r.writes,
    r.wait_type,
    r.last_wait_type,
    r.wait_resource,
    espera_ms         = r.wait_time,
    banco             = DB_NAME(r.database_id),
    s.login_name,
    s.host_name,
    s.program_name,
    percentual        = r.percent_complete,
    comando_completo  = t.text,
    comando_atual     = SUBSTRING(
                            t.text,
                            (r.statement_start_offset / 2) + 1,
                            ((CASE r.statement_end_offset
                                  WHEN -1 THEN DATALENGTH(t.text)
                                  ELSE r.statement_end_offset
                              END - r.statement_start_offset) / 2) + 1)
FROM sys.dm_exec_requests AS r
INNER JOIN sys.dm_exec_sessions AS s
        ON s.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE s.is_user_process = 1
  AND r.session_id <> @@SPID
ORDER BY r.total_elapsed_time DESC;


/* ---------------------------------------------------------------------------
   BLOCO 3 - Bloqueio neste instante
   Nenhuma linha aqui NAO descarta bloqueio intermitente. Execute algumas vezes.
   Para a cadeia completa use arvore-de-bloqueio-hierarquica.sql.
   --------------------------------------------------------------------------- */
SELECT
    bloco                 = '3 - Bloqueio',
    bloqueador            = r.blocking_session_id,
    bloqueado             = r.session_id,
    bloqueado_ha_seg      = r.wait_time / 1000,
    r.wait_type,
    r.wait_resource,
    banco_do_bloqueado    = DB_NAME(r.database_id),
    login_do_bloqueado    = s.login_name,
    programa_do_bloqueado = s.program_name
FROM sys.dm_exec_requests AS r
INNER JOIN sys.dm_exec_sessions AS s
        ON s.session_id = r.session_id
WHERE r.blocking_session_id <> 0
  AND r.blocking_session_id <> r.session_id   /* auto-bloqueio por paralelismo */
ORDER BY r.wait_time DESC;


/* ---------------------------------------------------------------------------
   BLOCO 4 - Top 10 esperas acumuladas desde o restart
   A lista de exclusao remove esperas ociosas e de background, que dominariam
   o resultado sem significar nada.
   --------------------------------------------------------------------------- */
SELECT TOP (10)
    bloco                 = '4 - Waits acumulados',
    ws.wait_type,
    espera_total_seg      = ws.wait_time_ms / 1000.0,
    espera_de_recurso_seg = (ws.wait_time_ms - ws.signal_wait_time_ms) / 1000.0,
    espera_por_cpu_seg    = ws.signal_wait_time_ms / 1000.0,
    ocorrencias           = ws.waiting_tasks_count,
    espera_media_ms       = CASE
                                WHEN ws.waiting_tasks_count = 0 THEN 0
                                ELSE ws.wait_time_ms * 1.0 / ws.waiting_tasks_count
                            END
FROM sys.dm_os_wait_stats AS ws
WHERE ws.waiting_tasks_count > 0
  AND ws.wait_type NOT IN (
        N'BROKER_EVENTHANDLER',          N'BROKER_RECEIVE_WAITFOR',
        N'BROKER_TASK_STOP',             N'BROKER_TO_FLUSH',
        N'BROKER_TRANSMITTER',           N'CHECKPOINT_QUEUE',
        N'CHKPT',                        N'CLR_AUTO_EVENT',
        N'CLR_MANUAL_EVENT',             N'CLR_SEMAPHORE',
        N'DBMIRROR_DBM_EVENT',           N'DBMIRROR_EVENTS_QUEUE',
        N'DBMIRROR_WORKER_QUEUE',        N'DBMIRRORING_CMD',
        N'DIRTY_PAGE_POLL',              N'DISPATCHER_QUEUE_SEMAPHORE',
        N'EXECSYNC',                     N'FSAGENT',
        N'FT_IFTS_SCHEDULER_IDLE_WAIT',  N'FT_IFTSHC_MUTEX',
        N'HADR_CLUSAPI_CALL',            N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        N'HADR_LOGCAPTURE_WAIT',         N'HADR_NOTIFICATION_DEQUEUE',
        N'HADR_TIMER_TASK',              N'HADR_WORK_QUEUE',
        N'KSOURCE_WAKEUP',               N'LAZYWRITER_SLEEP',
        N'LOGMGR_QUEUE',                 N'MEMORY_ALLOCATION_EXT',
        N'ONDEMAND_TASK_QUEUE',          N'PARALLEL_REDO_DRAIN_WORKER',
        N'PARALLEL_REDO_LOG_CACHE',      N'PARALLEL_REDO_TRAN_LIST',
        N'PARALLEL_REDO_WORKER_SYNC',    N'PARALLEL_REDO_WORKER_WAIT_WORK',
        N'PREEMPTIVE_XE_GETTARGETSTATE', N'PWAIT_ALL_COMPONENTS_INITIALIZED',
        N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
        N'QDS_ASYNC_QUEUE',              N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
        N'QDS_SHUTDOWN_QUEUE',           N'REDO_THREAD_PENDING_WORK',
        N'REQUEST_FOR_DEADLOCK_SEARCH',  N'RESOURCE_QUEUE',
        N'SERVER_IDLE_CHECK',            N'SLEEP_BPOOL_FLUSH',
        N'SLEEP_DBSTARTUP',              N'SLEEP_DCOMSTARTUP',
        N'SLEEP_MASTERDBREADY',          N'SLEEP_MASTERMDREADY',
        N'SLEEP_MASTERUPGRADED',         N'SLEEP_MSDBSTARTUP',
        N'SLEEP_SYSTEMTASK',             N'SLEEP_TASK',
        N'SLEEP_TEMPDBSTARTUP',          N'SNI_HTTP_ACCEPT',
        N'SOS_WORK_DISPATCHER',          N'SP_SERVER_DIAGNOSTICS_SLEEP',
        N'SQLTRACE_BUFFER_FLUSH',        N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
        N'SQLTRACE_WAIT_ENTRIES',        N'WAIT_FOR_RESULTS',
        N'WAITFOR',                      N'WAITFOR_TASKSHUTDOWN',
        N'WAIT_XTP_RECOVERY',            N'WAIT_XTP_HOST_WAIT',
        N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',N'WAIT_XTP_CKPT_CLOSE',
        N'XE_DISPATCHER_JOIN',           N'XE_DISPATCHER_WAIT',
        N'XE_TIMER_EVENT',               N'XE_LIVE_TARGET_TVF')
ORDER BY ws.wait_time_ms DESC;


/* ---------------------------------------------------------------------------
   BLOCO 5 - Uso do tempdb
   Identifica qual consumidor esta ocupando o tempdb: objeto de usuario,
   objeto interno (sort/hash/spill) ou version store.
   --------------------------------------------------------------------------- */
SELECT
    bloco                     = '5 - tempdb',
    total_mb                  = SUM(fsu.total_page_count)                 * 8 / 1024.0,
    livre_mb                  = SUM(fsu.unallocated_extent_page_count)    * 8 / 1024.0,
    objetos_de_usuario_mb     = SUM(fsu.user_object_reserved_page_count)  * 8 / 1024.0,
    objetos_internos_mb       = SUM(fsu.internal_object_reserved_page_count) * 8 / 1024.0,
    version_store_mb          = SUM(fsu.version_store_reserved_page_count)   * 8 / 1024.0
FROM tempdb.sys.dm_db_file_space_usage AS fsu;


/* ---------------------------------------------------------------------------
   BLOCO 6 - Memoria: Page Life Expectancy e concessoes pendentes
   O valor absoluto de PLE isolado diz pouco. O que importa e a TENDENCIA e a
   comparacao com o comportamento normal desta instancia.
   --------------------------------------------------------------------------- */
SELECT
    bloco                    = '6 - Memoria',
    page_life_expectancy_seg = MAX(CASE WHEN RTRIM(pc.counter_name) = 'Page life expectancy'
                                        THEN pc.cntr_value END),
    memoria_concedida_kb     = MAX(CASE WHEN RTRIM(pc.counter_name) = 'Memory Grants Outstanding'
                                        THEN pc.cntr_value END),
    concessoes_pendentes     = MAX(CASE WHEN RTRIM(pc.counter_name) = 'Memory Grants Pending'
                                        THEN pc.cntr_value END)
FROM sys.dm_os_performance_counters AS pc
WHERE RTRIM(pc.counter_name) IN ('Page life expectancy',
                                 'Memory Grants Outstanding',
                                 'Memory Grants Pending');

/* ===========================================================================
   COMO LER O RESULTADO

   Bloco 3 com linhas          -> bloqueio. Va para quem-esta-bloqueando-quem.sql
   Bloco 2 com muitos RUNNABLE -> fila por CPU
   Bloco 4 com LCK_M_*         -> bloqueio
   Bloco 4 com PAGEIOLATCH_*   -> I/O ou falta de indice
   Bloco 4 com WRITELOG        -> latencia do transaction log
   Bloco 4 com RESOURCE_SEMAPHORE ou bloco 6 com concessoes pendentes > 0
                               -> pressao de memoria
   Bloco 4 com ASYNC_NETWORK_IO-> a APLICACAO nao consome o resultado.
                                  O problema nao esta no banco.
   Bloco 5 com version_store alto -> transacao antiga aberta segurando versoes
   =========================================================================== */
