/* ===========================================================================
   NOME       : queries-que-mais-fazem-io.sql
   OBJETIVO   : Identificar as queries que mais leem e escrevem, e -- mais
                importante -- as que leem MUITO para retornar POUCO, que sao as
                candidatas obvias a indice.

   COMPATIBILIDADE : SQL Server 2012+ (11.x). Azure SQL Database: sim.
   IMPACTO         : Baixo. Leitura do cache de planos.
   PERMISSOES      : VIEW SERVER STATE.
   TEMPO ESTIMADO  : 2 a 20 segundos.

   CONCEITO   : leitura LOGICA e a pagina lida do buffer pool (memoria);
                leitura FISICA e a pagina que precisou vir do disco.
                Leitura logica alta ja e problema, mesmo com tudo em memoria:
                ela custa CPU e indica que a query esta percorrendo dados
                demais para o que entrega.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

DECLARE @linhas INT = 25;

/* ---------------------------------------------------------------------------
   BLOCO 1 - Por leitura logica TOTAL
   --------------------------------------------------------------------------- */
SELECT TOP (@linhas)
    ranking_por           = 'leitura logica total',
    leituras_logicas      = qs.total_logical_reads,
    leituras_por_execucao = qs.total_logical_reads / NULLIF(qs.execution_count,0),
    leituras_fisicas      = qs.total_physical_reads,
    escritas_logicas      = qs.total_logical_writes,
    execucoes             = qs.execution_count,
    duracao_media_ms      = qs.total_elapsed_time / 1000.0 / NULLIF(qs.execution_count,0),
    cpu_media_ms          = qs.total_worker_time  / 1000.0 / NULLIF(qs.execution_count,0),
    linhas_medias         = qs.total_rows / NULLIF(qs.execution_count,0),
    /* O indicador mais acionavel deste script: */
    paginas_por_linha     = CASE WHEN qs.total_rows > 0
                                 THEN qs.total_logical_reads * 1.0 / qs.total_rows END,
    ultima_execucao       = qs.last_execution_time,
    objeto                = COALESCE(OBJECT_SCHEMA_NAME(t.objectid, t.dbid)
                                     + '.' + OBJECT_NAME(t.objectid, t.dbid), '(ad hoc)'),
    banco                 = DB_NAME(t.dbid),
    comando               = SUBSTRING(
                                t.text,
                                (qs.statement_start_offset / 2) + 1,
                                ((CASE qs.statement_end_offset
                                      WHEN -1 THEN DATALENGTH(t.text)
                                      ELSE qs.statement_end_offset
                                  END - qs.statement_start_offset) / 2) + 1),
    plano                 = p.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS t
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS p
ORDER BY qs.total_logical_reads DESC;


/* ---------------------------------------------------------------------------
   BLOCO 2 - Le muito e devolve pouco: candidatas diretas a indice
   Uma query que le 500 mil paginas para devolver 3 linhas esta varrendo a
   tabela inteira. Isso e falta de indice ou predicado nao SARGable.
   --------------------------------------------------------------------------- */
SELECT TOP (@linhas)
    ranking_por           = 'paginas lidas por linha retornada',
    paginas_por_linha     = qs.total_logical_reads * 1.0 / NULLIF(qs.total_rows,0),
    leituras_por_execucao = qs.total_logical_reads / NULLIF(qs.execution_count,0),
    linhas_medias         = qs.total_rows / NULLIF(qs.execution_count,0),
    execucoes             = qs.execution_count,
    duracao_media_ms      = qs.total_elapsed_time / 1000.0 / NULLIF(qs.execution_count,0),
    objeto                = COALESCE(OBJECT_SCHEMA_NAME(t.objectid, t.dbid)
                                     + '.' + OBJECT_NAME(t.objectid, t.dbid), '(ad hoc)'),
    comando               = SUBSTRING(
                                t.text,
                                (qs.statement_start_offset / 2) + 1,
                                ((CASE qs.statement_end_offset
                                      WHEN -1 THEN DATALENGTH(t.text)
                                      ELSE qs.statement_end_offset
                                  END - qs.statement_start_offset) / 2) + 1),
    plano                 = p.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS t
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS p
WHERE qs.total_rows > 0
  AND qs.execution_count >= 5
  AND qs.total_logical_reads > 10000
ORDER BY (qs.total_logical_reads * 1.0 / NULLIF(qs.total_rows,0)) DESC;


/* ---------------------------------------------------------------------------
   BLOCO 3 - Por ESCRITA: cargas, ETL e operacoes de manutencao
   --------------------------------------------------------------------------- */
SELECT TOP (@linhas)
    ranking_por           = 'escrita logica total',
    escritas_logicas      = qs.total_logical_writes,
    escritas_por_execucao = qs.total_logical_writes / NULLIF(qs.execution_count,0),
    execucoes             = qs.execution_count,
    duracao_media_ms      = qs.total_elapsed_time / 1000.0 / NULLIF(qs.execution_count,0),
    ultima_execucao       = qs.last_execution_time,
    objeto                = COALESCE(OBJECT_SCHEMA_NAME(t.objectid, t.dbid)
                                     + '.' + OBJECT_NAME(t.objectid, t.dbid), '(ad hoc)'),
    comando               = SUBSTRING(
                                t.text,
                                (qs.statement_start_offset / 2) + 1,
                                ((CASE qs.statement_end_offset
                                      WHEN -1 THEN DATALENGTH(t.text)
                                      ELSE qs.statement_end_offset
                                  END - qs.statement_start_offset) / 2) + 1)
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
WHERE qs.total_logical_writes > 0
ORDER BY qs.total_logical_writes DESC;

/* ===========================================================================
   COMO LER O RESULTADO

   paginas_por_linha MUITO ALTO (centenas ou milhares)
       A query percorre um volume enorme para devolver pouca coisa.
       Causas, em ordem de frequencia:
         1. falta de indice que suporte o predicado
              -> ../indexes/encontrar-indices-ausentes.sql
         2. predicado nao SARGable (funcao sobre a coluna, LIKE '%x', conversao
            implicita de tipo)
              -> sargability-e-indices-ignorados.md
         3. juncao sem predicado adequado, gerando produto intermediario grande
         4. estatistica desatualizada levando o otimizador a escolher Scan
              -> estatisticas-desatualizadas.md

   leituras_fisicas alto e leituras_logicas baixo
       Os dados nao estao em memoria. Pode ser buffer pool pequeno para o
       volume de trabalho, ou primeira execucao apos restart.

   BLOCO 3 dominado por uma unica carga
       Avalie processar em lotes com COMMIT frequente. Alem de reduzir o pico
       de I/O, evita escalonamento de lock e transaction log gigante.

   POR QUE ISSO IMPORTA MAIS QUE O DISCO
       Na pratica, a maioria dos "problemas de storage" em SQL Server sao
       problemas de plano de execucao. Trocar o subsistema de disco resolve o
       sintoma por alguns meses; criar o indice certo resolve o problema.
   =========================================================================== */
