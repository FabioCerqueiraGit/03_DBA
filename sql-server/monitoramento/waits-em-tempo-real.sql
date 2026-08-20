/* ===========================================================================
   NOME       : waits-em-tempo-real.sql
   OBJETIVO   : Mostrar o que as sessoes estao esperando NESTE MOMENTO, sem a
                diluicao das estatisticas acumuladas desde o restart.

   COMPATIBILIDADE : SQL Server 2012+ (11.x). Azure SQL Database: sim.
   IMPACTO         : Nenhum. Somente leitura.
   PERMISSOES      : VIEW SERVER STATE.
   TEMPO ESTIMADO  : < 2 segundos.

   QUANDO USAR : durante um incidente. E a visao correta para "o que esta
                travando AGORA". Para tendencia historica use
                analisar-waits-acumulados.sql.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

/* ---------------------------------------------------------------------------
   BLOCO 1 - Tarefas esperando agora, agrupadas por tipo de espera
   --------------------------------------------------------------------------- */
SELECT
    wt.wait_type,
    tarefas_esperando = COUNT(*),
    espera_total_ms   = SUM(wt.wait_duration_ms),
    espera_maxima_ms  = MAX(wt.wait_duration_ms),
    sessoes           = STUFF((
                            SELECT ', ' + CAST(wt2.session_id AS VARCHAR(10))
                            FROM sys.dm_os_waiting_tasks AS wt2
                            WHERE wt2.wait_type = wt.wait_type
                              AND wt2.session_id IS NOT NULL
                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
FROM sys.dm_os_waiting_tasks AS wt
WHERE wt.session_id IS NOT NULL
  AND wt.session_id <> @@SPID
  AND wt.wait_type NOT IN (N'WAITFOR', N'BROKER_RECEIVE_WAITFOR',
                           N'SLEEP_TASK', N'LAZYWRITER_SLEEP',
                           N'XE_TIMER_EVENT', N'XE_DISPATCHER_WAIT',
                           N'DIRTY_PAGE_POLL', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
                           N'SP_SERVER_DIAGNOSTICS_SLEEP', N'REQUEST_FOR_DEADLOCK_SEARCH')
GROUP BY wt.wait_type
ORDER BY espera_total_ms DESC;


/* ---------------------------------------------------------------------------
   BLOCO 2 - Detalhe por tarefa, com quem esta bloqueando e o comando
   --------------------------------------------------------------------------- */
SELECT
    wt.session_id,
    wt.wait_type,
    espera_ms          = wt.wait_duration_ms,
    wt.resource_description,
    bloqueado_por      = wt.blocking_session_id,
    r.status,
    r.command,
    duracao_request_seg = r.total_elapsed_time / 1000,
    banco              = DB_NAME(r.database_id),
    s.login_name,
    s.host_name,
    s.program_name,
    comando_atual      = SUBSTRING(
                             t.text,
                             (r.statement_start_offset / 2) + 1,
                             ((CASE r.statement_end_offset
                                   WHEN -1 THEN DATALENGTH(t.text)
                                   ELSE r.statement_end_offset
                               END - r.statement_start_offset) / 2) + 1)
FROM sys.dm_os_waiting_tasks AS wt
LEFT JOIN sys.dm_exec_requests AS r
       ON r.session_id = wt.session_id
LEFT JOIN sys.dm_exec_sessions AS s
       ON s.session_id = wt.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE wt.session_id IS NOT NULL
  AND wt.session_id <> @@SPID
  AND wt.wait_type NOT IN (N'WAITFOR', N'BROKER_RECEIVE_WAITFOR',
                           N'SLEEP_TASK', N'LAZYWRITER_SLEEP',
                           N'XE_TIMER_EVENT', N'XE_DISPATCHER_WAIT',
                           N'DIRTY_PAGE_POLL', N'SP_SERVER_DIAGNOSTICS_SLEEP',
                           N'REQUEST_FOR_DEADLOCK_SEARCH')
ORDER BY wt.wait_duration_ms DESC;

/* ===========================================================================
   COMO LER O RESULTADO

   Uma linha por TAREFA, nao por sessao: uma consulta paralela aparece varias
   vezes, uma por thread. Isso e esperado.

   resource_description em LCK_M_*    -> o recurso disputado (banco, objeto,
                                         pagina, chave). Confirme a cadeia com
                                         ../troubleshooting/arvore-de-bloqueio-hierarquica.sql

   resource_description em PAGEIOLATCH_* comeca com o database_id e file_id da
   pagina sendo lida do disco.

   Nenhuma linha, mas o sistema esta lento
       Ninguem esta esperando por recurso -> o gargalo e CPU ou esta fora do
       banco. Va para ../performance/queries-que-mais-consomem-cpu.sql
   =========================================================================== */
