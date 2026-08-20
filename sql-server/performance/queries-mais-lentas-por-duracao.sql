/* ===========================================================================
   NOME       : queries-mais-lentas-por-duracao.sql
   OBJETIVO   : Listar as queries de maior duracao, separando o tempo gasto em
                CPU do tempo gasto ESPERANDO -- que apontam para causas
                diferentes.

   COMPATIBILIDADE : SQL Server 2012+ (11.x). Azure SQL Database: sim.
                     BLOCO 3 (Query Store): SQL Server 2016+ (13.x), com Query
                     Store habilitado no banco.
   IMPACTO         : Baixo.
   PERMISSOES      : VIEW SERVER STATE. Para o BLOCO 3, permissao de leitura
                     nas views do Query Store do banco.
   TEMPO ESTIMADO  : 2 a 30 segundos.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

DECLARE @linhas INT = 25;

/* ---------------------------------------------------------------------------
   BLOCO 1 - Maior duracao MEDIA por execucao
   A diferenca entre duracao e CPU e o tempo ESPERANDO por algo.
   --------------------------------------------------------------------------- */
SELECT TOP (@linhas)
    duracao_media_ms   = qs.total_elapsed_time / 1000.0 / NULLIF(qs.execution_count,0),
    cpu_media_ms       = qs.total_worker_time  / 1000.0 / NULLIF(qs.execution_count,0),
    espera_media_ms    = (qs.total_elapsed_time - qs.total_worker_time)
                         / 1000.0 / NULLIF(qs.execution_count,0),
    perfil = CASE
        WHEN qs.total_worker_time * 1.0 / NULLIF(qs.total_elapsed_time,0) > 0.8
            THEN 'LIGADA A CPU - trabalho de processamento'
        WHEN qs.total_worker_time * 1.0 / NULLIF(qs.total_elapsed_time,0) < 0.3
            THEN 'ESPERANDO - I/O, bloqueio ou rede'
        ELSE 'misto'
    END,
    duracao_maxima_ms  = qs.max_elapsed_time / 1000.0,
    duracao_minima_ms  = qs.min_elapsed_time / 1000.0,
    /* Variacao grande entre min e max e assinatura de parameter sniffing */
    variacao           = CASE WHEN qs.min_elapsed_time > 0
                                   AND qs.max_elapsed_time / NULLIF(qs.min_elapsed_time,0) > 100
                              THEN 'ALTA - suspeitar de parameter sniffing'
                              ELSE 'normal' END,
    execucoes          = qs.execution_count,
    duracao_total_seg  = qs.total_elapsed_time / 1000000.0,
    leituras_medias    = qs.total_logical_reads / NULLIF(qs.execution_count,0),
    linhas_medias      = qs.total_rows / NULLIF(qs.execution_count,0),
    primeira_compilacao = qs.creation_time,
    ultima_execucao    = qs.last_execution_time,
    objeto             = COALESCE(OBJECT_SCHEMA_NAME(t.objectid, t.dbid)
                                  + '.' + OBJECT_NAME(t.objectid, t.dbid), '(ad hoc)'),
    banco              = DB_NAME(t.dbid),
    comando            = SUBSTRING(
                             t.text,
                             (qs.statement_start_offset / 2) + 1,
                             ((CASE qs.statement_end_offset
                                   WHEN -1 THEN DATALENGTH(t.text)
                                   ELSE qs.statement_end_offset
                               END - qs.statement_start_offset) / 2) + 1),
    plano              = p.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS t
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS p
WHERE qs.execution_count >= 3
ORDER BY (qs.total_elapsed_time / NULLIF(qs.execution_count,0)) DESC;


/* ---------------------------------------------------------------------------
   BLOCO 2 - Maior duracao TOTAL: onde o tempo do sistema realmente foi
   --------------------------------------------------------------------------- */
SELECT TOP (@linhas)
    duracao_total_seg = qs.total_elapsed_time / 1000000.0,
    execucoes         = qs.execution_count,
    duracao_media_ms  = qs.total_elapsed_time / 1000.0 / NULLIF(qs.execution_count,0),
    objeto            = COALESCE(OBJECT_SCHEMA_NAME(t.objectid, t.dbid)
                                 + '.' + OBJECT_NAME(t.objectid, t.dbid), '(ad hoc)'),
    comando           = SUBSTRING(
                            t.text,
                            (qs.statement_start_offset / 2) + 1,
                            ((CASE qs.statement_end_offset
                                  WHEN -1 THEN DATALENGTH(t.text)
                                  ELSE qs.statement_end_offset
                              END - qs.statement_start_offset) / 2) + 1),
    plano             = p.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS t
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS p
ORDER BY qs.total_elapsed_time DESC;


/* ---------------------------------------------------------------------------
   BLOCO 3 - QUERY STORE: a unica forma confiavel de responder
            "essa query era rapida semana passada, o que mudou?"
   EXIGE SQL Server 2016+ e Query Store habilitado no banco corrente.
   Execute no contexto do banco a investigar (USE [<BANCO>]).
   --------------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM sys.database_query_store_options
           WHERE actual_state <> 0)
BEGIN
    SELECT TOP (25)
        q.query_id,
        qsp.plan_id,
        qt.query_sql_text,
        duracao_media_ms  = AVG(rs.avg_duration) / 1000.0,
        cpu_media_ms      = AVG(rs.avg_cpu_time) / 1000.0,
        execucoes         = SUM(rs.count_executions),
        primeira_execucao = MIN(rs.first_execution_time),
        ultima_execucao   = MAX(rs.last_execution_time),
        /* Mais de um plano para a mesma query = candidato a regressao de plano.
           Subconsulta em vez de COUNT(DISTINCT) OVER(), que o SQL Server
           nao suporta. */
        planos_distintos  = (SELECT COUNT(*)
                             FROM sys.query_store_plan AS pl
                             WHERE pl.query_id = q.query_id)
    FROM sys.query_store_query            AS q
    INNER JOIN sys.query_store_query_text AS qt  ON qt.query_text_id = q.query_text_id
    INNER JOIN sys.query_store_plan       AS qsp ON qsp.query_id     = q.query_id
    INNER JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id     = qsp.plan_id
    GROUP BY q.query_id, qsp.plan_id, qt.query_sql_text
    ORDER BY AVG(rs.avg_duration) DESC;
END
ELSE
BEGIN
    PRINT 'Query Store nao esta habilitado neste banco. Para habilitar:';
    PRINT '  ALTER DATABASE [<BANCO>] SET QUERY_STORE = ON;';
    PRINT '  ALTER DATABASE [<BANCO>] SET QUERY_STORE (OPERATION_MODE = READ_WRITE);';
    PRINT 'Avalie o impacto e o espaco antes de habilitar em producao.';
END;

/* ===========================================================================
   COMO LER O RESULTADO

   perfil = 'LIGADA A CPU'
       A query esta processando de verdade. Otimize o plano:
       ../indexes/encontrar-indices-ausentes.sql e como-ler-um-plano-de-execucao.md

   perfil = 'ESPERANDO'
       A query passa a maior parte do tempo parada. Descubra esperando o que:
       ../monitoramento/waits-em-tempo-real.sql
       Se for bloqueio: ../troubleshooting/quem-esta-bloqueando-quem.sql

   variacao = 'ALTA - suspeitar de parameter sniffing'
       min_elapsed_time e max_elapsed_time muito distantes indicam que a MESMA
       query, com o MESMO plano, se comporta de forma radicalmente diferente
       conforme o parametro. Va para parameter-sniffing.md

   planos_distintos > 1 no BLOCO 3
       A query tem mais de um plano no historico. Compare-os no Query Store:
       e assim que se prova uma regressao de plano e, se necessario, se forca
       o plano bom com sp_query_store_force_plan.

   LIMITACAO IMPORTANTE DOS BLOCOS 1 E 2
       Eles enxergam apenas o cache de planos. Queries com RECOMPILE e planos
       ja despejados nao aparecem. Para historico confiavel, Query Store.
   =========================================================================== */
