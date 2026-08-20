/* ===========================================================================
   NOME       : analisar-waits-acumulados.sql
   OBJETIVO   : Mostrar em que a instancia gastou tempo ESPERANDO desde o
                ultimo restart, com percentual acumulado, para direcionar a
                investigacao de performance.

   COMPATIBILIDADE : SQL Server 2012+ (11.x).
                     Azure SQL Database: use sys.dm_db_wait_stats no lugar de
                     sys.dm_os_wait_stats (escopo de banco).
   IMPACTO         : Nenhum. Somente leitura.
   PERMISSOES      : VIEW SERVER STATE.
   TEMPO ESTIMADO  : < 2 segundos.

   ATENCAO    : Esta e a visao ACUMULADA desde o restart. Durante um incidente
                ela dilui o problema em semanas de operacao normal -- prefira
                waits-em-tempo-real.sql. Confira o uptime antes de concluir
                qualquer coisa: com poucas horas de uptime o resultado nao e
                representativo.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

/* Uptime primeiro: sem ele o resto nao se interpreta. */
SELECT
    inicio_da_instancia = sqlserver_start_time,
    uptime_horas        = DATEDIFF(HOUR, sqlserver_start_time, SYSDATETIME()),
    representativo      = CASE
                              WHEN DATEDIFF(HOUR, sqlserver_start_time, SYSDATETIME()) < 24
                              THEN 'NAO - menos de 24h de uptime'
                              ELSE 'sim' END
FROM sys.dm_os_sys_info;

/* Waits relevantes com percentual acumulado.
   Corta na faixa dos 95% para nao poluir com centenas de esperas irrelevantes. */
WITH Esperas AS
(
    SELECT
        ws.wait_type,
        espera_seg          = ws.wait_time_ms / 1000.0,
        espera_recurso_seg  = (ws.wait_time_ms - ws.signal_wait_time_ms) / 1000.0,
        espera_cpu_seg      = ws.signal_wait_time_ms / 1000.0,
        ocorrencias         = ws.waiting_tasks_count,
        percentual          = 100.0 * ws.wait_time_ms
                              / NULLIF(SUM(ws.wait_time_ms) OVER (), 0),
        linha               = ROW_NUMBER() OVER (ORDER BY ws.wait_time_ms DESC)
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
)
SELECT
    e.wait_type,
    e.espera_seg,
    e.espera_recurso_seg,
    e.espera_cpu_seg,
    e.ocorrencias,
    espera_media_ms = CASE WHEN e.ocorrencias = 0 THEN 0
                           ELSE e.espera_seg * 1000.0 / e.ocorrencias END,
    percentual      = CAST(e.percentual AS DECIMAL(5,2)),
    acumulado       = CAST(SUM(e.percentual) OVER (ORDER BY e.linha) AS DECIMAL(5,2)),
    familia = CASE
        WHEN e.wait_type LIKE 'LCK[_]%'        THEN 'BLOQUEIO - contencao de lock'
        WHEN e.wait_type LIKE 'PAGEIOLATCH%'   THEN 'I/O - leitura de pagina do disco'
        WHEN e.wait_type LIKE 'WRITELOG%'      THEN 'I/O - gravacao no transaction log'
        WHEN e.wait_type LIKE 'IO[_]COMPLETION%' OR e.wait_type LIKE 'ASYNC_IO%'
                                               THEN 'I/O - operacao de arquivo'
        WHEN e.wait_type LIKE 'PAGELATCH%'     THEN 'CONTENCAO - pagina em memoria (ver tempdb)'
        WHEN e.wait_type LIKE 'LATCH[_]%'      THEN 'CONTENCAO - estrutura interna'
        WHEN e.wait_type = 'SOS_SCHEDULER_YIELD' THEN 'CPU - pressao de processador'
        WHEN e.wait_type LIKE 'CX%'            THEN 'PARALELISMO'
        WHEN e.wait_type LIKE 'RESOURCE_SEMAPHORE%' THEN 'MEMORIA - fila por concessao'
        WHEN e.wait_type = 'THREADPOOL'        THEN 'GRAVE - esgotamento de worker threads'
        WHEN e.wait_type = 'ASYNC_NETWORK_IO'  THEN 'APLICACAO - nao consome o resultado'
        WHEN e.wait_type LIKE 'BACKUP%'        THEN 'BACKUP'
        ELSE 'outro'
    END
FROM Esperas AS e
WHERE e.percentual >= 0.5      /* descarta ruido */
ORDER BY e.linha;

/* ===========================================================================
   COMO LER O RESULTADO

   Olhe a coluna 'familia' antes de decorar nomes de wait type.

   BLOQUEIO      -> ../troubleshooting/quem-esta-bloqueando-quem.sql
   I/O           -> ../performance/queries-que-mais-fazem-io.sql
                    e ../indexes/encontrar-indices-ausentes.sql
   CPU           -> ../performance/queries-que-mais-consomem-cpu.sql
   MEMORIA       -> memory-grants-e-fila-de-memoria.sql
   PARALELISMO   -> CXPACKET/CXCONSUMER sozinhos NAO sao problema. Eles apenas
                    indicam que houve paralelismo. Olhe a segunda espera da
                    lista para saber o que realmente atrasou.
   THREADPOOL    -> situacao grave, quase sempre CONSEQUENCIA de bloqueio
                    massivo. Trate o bloqueio, nao o threadpool.
   APLICACAO     -> ASYNC_NETWORK_IO alto quase nunca e "rede lenta". Significa
                    que a aplicacao pediu um resultado grande e processa linha
                    a linha enquanto o SQL Server segura o restante.

   PARA ZERAR AS ESTATISTICAS (util para medir uma janela especifica):

       -- ATENCAO: afeta a instancia inteira e apaga o historico acumulado.
       -- Nao execute em producao sem combinar com o time.
       -- DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);
   =========================================================================== */
