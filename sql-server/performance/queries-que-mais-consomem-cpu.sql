/* ===========================================================================
   NOME       : queries-que-mais-consomem-cpu.sql
   OBJETIVO   : Identificar as queries que mais consumiram CPU desde o ultimo
                restart, separando o caso "uma query cara" do caso "milhares de
                execucoes de uma query barata" -- que exigem correcoes opostas.

   COMPATIBILIDADE : SQL Server 2012+ (11.x). Azure SQL Database: sim.
   IMPACTO         : Baixo. Leitura do cache de planos. Em instancias com cache
                     muito grande pode levar alguns segundos.
   PERMISSOES      : VIEW SERVER STATE.
   TEMPO ESTIMADO  : 2 a 20 segundos.

   ATENCAO    : sys.dm_exec_query_stats so enxerga o que esta NO CACHE DE
                PLANOS. Ficam de fora:
                  - queries com RECOMPILE (nunca entram no cache);
                  - planos ja despejados por pressao de memoria;
                  - tudo, apos DBCC FREEPROCCACHE ou restart.
                Para historico confiavel, use Query Store (SQL Server 2016+).

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

DECLARE @linhas INT = 25;   /* ajuste conforme a necessidade */

/* ---------------------------------------------------------------------------
   BLOCO 1 - Por CPU TOTAL: onde o processador realmente foi gasto
   E o ranking que importa para reduzir consumo global de CPU.
   --------------------------------------------------------------------------- */
SELECT TOP (@linhas)
    ranking_por          = 'CPU total',
    cpu_total_seg        = qs.total_worker_time / 1000000.0,
    cpu_media_ms         = qs.total_worker_time / 1000.0 / NULLIF(qs.execution_count,0),
    execucoes            = qs.execution_count,
    duracao_total_seg    = qs.total_elapsed_time / 1000000.0,
    duracao_media_ms     = qs.total_elapsed_time / 1000.0 / NULLIF(qs.execution_count,0),
    leituras_logicas_med = qs.total_logical_reads / NULLIF(qs.execution_count,0),
    linhas_medias        = qs.total_rows / NULLIF(qs.execution_count,0),
    /* CPU maior que duracao indica paralelismo: varias threads somando tempo */
    indicio_paralelismo  = CASE WHEN qs.total_worker_time > qs.total_elapsed_time * 1.2
                                THEN 'SIM - query paralela' ELSE 'nao' END,
    primeira_compilacao  = qs.creation_time,
    ultima_execucao      = qs.last_execution_time,
    objeto               = COALESCE(OBJECT_SCHEMA_NAME(t.objectid, t.dbid)
                                    + '.' + OBJECT_NAME(t.objectid, t.dbid),
                                    '(ad hoc)'),
    banco                = DB_NAME(t.dbid),
    comando              = SUBSTRING(
                               t.text,
                               (qs.statement_start_offset / 2) + 1,
                               ((CASE qs.statement_end_offset
                                     WHEN -1 THEN DATALENGTH(t.text)
                                     ELSE qs.statement_end_offset
                                 END - qs.statement_start_offset) / 2) + 1),
    plano                = p.query_plan,
    qs.query_hash
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS t
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS p
ORDER BY qs.total_worker_time DESC;


/* ---------------------------------------------------------------------------
   BLOCO 2 - Por CPU MEDIA POR EXECUCAO: as queries individualmente caras
   Filtra ruido de queries executadas pouquissimas vezes.
   --------------------------------------------------------------------------- */
SELECT TOP (@linhas)
    ranking_por      = 'CPU media por execucao',
    cpu_media_ms     = qs.total_worker_time / 1000.0 / NULLIF(qs.execution_count,0),
    execucoes        = qs.execution_count,
    cpu_total_seg    = qs.total_worker_time / 1000000.0,
    duracao_media_ms = qs.total_elapsed_time / 1000.0 / NULLIF(qs.execution_count,0),
    ultima_execucao  = qs.last_execution_time,
    objeto           = COALESCE(OBJECT_SCHEMA_NAME(t.objectid, t.dbid)
                                + '.' + OBJECT_NAME(t.objectid, t.dbid), '(ad hoc)'),
    comando          = SUBSTRING(
                           t.text,
                           (qs.statement_start_offset / 2) + 1,
                           ((CASE qs.statement_end_offset
                                 WHEN -1 THEN DATALENGTH(t.text)
                                 ELSE qs.statement_end_offset
                             END - qs.statement_start_offset) / 2) + 1),
    plano            = p.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS t
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS p
WHERE qs.execution_count >= 5
ORDER BY (qs.total_worker_time / NULLIF(qs.execution_count,0)) DESC;


/* ---------------------------------------------------------------------------
   BLOCO 3 - Agrupado por query_hash: o mesmo texto com literais diferentes
   Se a aplicacao NAO parametriza, cada execucao vira uma entrada distinta no
   cache. Individualmente parecem baratas; somadas, dominam a CPU.
   --------------------------------------------------------------------------- */
SELECT TOP (@linhas)
    ranking_por        = 'query_hash agrupado',
    qs.query_hash,
    planos_no_cache    = COUNT(*),
    execucoes_totais   = SUM(qs.execution_count),
    cpu_total_seg      = SUM(qs.total_worker_time) / 1000000.0,
    cpu_media_ms       = SUM(qs.total_worker_time) / 1000.0 / NULLIF(SUM(qs.execution_count),0),
    diagnostico        = CASE WHEN COUNT(*) > 20
                              THEN 'MUITOS PLANOS PARA A MESMA QUERY - provavel falta de parametrizacao'
                              ELSE 'ok' END,
    exemplo_de_comando = MIN(SUBSTRING(
                               t.text,
                               (qs.statement_start_offset / 2) + 1,
                               ((CASE qs.statement_end_offset
                                     WHEN -1 THEN DATALENGTH(t.text)
                                     ELSE qs.statement_end_offset
                                 END - qs.statement_start_offset) / 2) + 1))
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
GROUP BY qs.query_hash
ORDER BY SUM(qs.total_worker_time) DESC;

/* ===========================================================================
   COMO LER O RESULTADO

   UMA query domina o BLOCO 1
       Otimize essa query. Comece pelo plano (coluna 'plano') e por
       ../indexes/encontrar-indices-ausentes.sql.

   BLOCO 1 pulverizado, com execucoes na casa dos milhares
       O problema NAO e a query, e o VOLUME DE CHAMADAS. Investigue a
       aplicacao: laco N+1, ausencia de cache, falta de paginacao.
       Veja ../../acesso-a-dados/entity-framework-core/ef-core-performance.md

   BLOCO 3 com 'MUITOS PLANOS PARA A MESMA QUERY'
       A aplicacao concatena literais em vez de usar parametros. Consequencias:
         - o otimizador compila um plano novo a cada execucao (queima CPU);
         - o cache de planos incha e despeja planos uteis;
         - e o codigo esta exposto a SQL Injection.
       CORRECAO: parametrizar na aplicacao. Veja
       ../../acesso-a-dados/ado-net/ado-net-fundamentos-seguros.md

   indicio_paralelismo = 'SIM'
       Nao e defeito por si so. Avalie 'cost threshold for parallelism' e
       'max degree of parallelism' da instancia -- o padrao de custo 5 e de
       1995 e faz o SQL Server paralelizar consultas triviais em servidores
       modernos.

   NA PRATICA
       CPU alta em SQL Server quase sempre e sintoma de plano ruim, nao de
       falta de processador. Trocar o servidor por um com mais nucleos costuma
       comprar alguns meses.
   =========================================================================== */
