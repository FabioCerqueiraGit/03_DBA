/* ===========================================================================
   NOME       : memory-grants-e-fila-de-memoria.sql
   OBJETIVO   : Diagnosticar pressao de memoria de execucao: quem recebeu
                concessao, quem esta na fila esperando, e quem pediu muito
                mais do que usou.

   COMPATIBILIDADE : BLOCOS 1 a 3: SQL Server 2012+ (11.x).
                     BLOCO 4: SQL Server 2016+ (13.x) -- as colunas de memory
                     grant em sys.dm_exec_query_stats (total_grant_kb,
                     max_grant_kb, total_used_grant_kb, max_used_grant_kb)
                     so existem a partir do SQL Server 2016. Em versoes
                     anteriores, remova o BLOCO 4: os blocos 1 a 3 continuam
                     respondendo a pergunta principal.
                     Azure SQL Database: sim.
   IMPACTO         : Nenhum. Somente leitura.
   PERMISSOES      : VIEW SERVER STATE.
   TEMPO ESTIMADO  : < 2 segundos.

   CONCEITO   : antes de executar, uma query que precisa ordenar ou fazer hash
                pede uma CONCESSAO de memoria (memory grant) baseada na
                ESTIMATIVA do otimizador. Se a estimativa esta errada:
                  - para mais: a query reserva memoria que nao usa e cria fila
                               para as demais (RESOURCE_SEMAPHORE);
                  - para menos: a query estoura e derrama no tempdb (spill).
                Nos dois casos a causa e a ESTIMATIVA, nao a memoria fisica.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

/* ---------------------------------------------------------------------------
   BLOCO 1 - Configuracao de memoria da instancia
   max server memory no valor padrao em servidor dedicado e um erro classico.
   --------------------------------------------------------------------------- */
SELECT
    configuracao   = c.name,
    valor_atual_mb = c.value_in_use,
    valor_definido = c.value,
    descricao      = c.description
FROM sys.configurations AS c
WHERE c.name IN ('max server memory (MB)',
                 'min server memory (MB)',
                 'min memory per query (KB)')
ORDER BY c.name;

SELECT
    memoria_fisica_mb          = si.physical_memory_kb / 1024,
    memoria_do_processo_mb     = pm.physical_memory_in_use_kb / 1024,
    sinal_de_pressao_externa   = pm.process_physical_memory_low,
    sinal_de_pressao_virtual   = pm.process_virtual_memory_low
FROM sys.dm_os_sys_info AS si
CROSS JOIN sys.dm_os_process_memory AS pm;


/* ---------------------------------------------------------------------------
   BLOCO 2 - Concessoes de memoria: concedidas e EM FILA
   Linhas com grant_time NULL sao as que estao esperando -- essas sao o
   problema visivel.
   --------------------------------------------------------------------------- */
SELECT
    situacao            = CASE WHEN mg.grant_time IS NULL
                               THEN 'NA FILA - esperando memoria'
                               ELSE 'concedida' END,
    mg.session_id,
    mg.request_time,
    mg.grant_time,
    esperando_ms        = mg.wait_time_ms,
    solicitado_mb       = mg.requested_memory_kb / 1024.0,
    concedido_mb        = mg.granted_memory_kb  / 1024.0,
    necessario_mb       = mg.required_memory_kb / 1024.0,
    usado_mb            = mg.used_memory_kb     / 1024.0,
    pico_usado_mb       = mg.max_used_memory_kb / 1024.0,
    ideal_mb            = mg.ideal_memory_kb    / 1024.0,
    /* Este e o indicador que denuncia estimativa ruim: */
    desperdicio_pct     = CASE WHEN mg.granted_memory_kb > 0
                               THEN 100.0 * (mg.granted_memory_kb - mg.max_used_memory_kb)
                                    / mg.granted_memory_kb
                               END,
    mg.dop,
    mg.queue_id,
    s.login_name,
    s.host_name,
    s.program_name,
    comando             = t.text
FROM sys.dm_exec_query_memory_grants AS mg
LEFT JOIN sys.dm_exec_sessions AS s
       ON s.session_id = mg.session_id
OUTER APPLY sys.dm_exec_sql_text(mg.sql_handle) AS t
ORDER BY
    CASE WHEN mg.grant_time IS NULL THEN 0 ELSE 1 END,
    mg.requested_memory_kb DESC;


/* ---------------------------------------------------------------------------
   BLOCO 3 - Contadores de memoria
   Page Life Expectancy isolado diz pouco: o que importa e a TENDENCIA.
   --------------------------------------------------------------------------- */
SELECT
    contador = RTRIM(pc.counter_name),
    objeto   = RTRIM(pc.object_name),
    valor    = pc.cntr_value
FROM sys.dm_os_performance_counters AS pc
WHERE RTRIM(pc.counter_name) IN ('Page life expectancy',
                                 'Memory Grants Pending',
                                 'Memory Grants Outstanding',
                                 'Target Server Memory (KB)',
                                 'Total Server Memory (KB)',
                                 'Lazy writes/sec',
                                 'Free Memory (KB)')
ORDER BY RTRIM(pc.object_name), RTRIM(pc.counter_name);


/* ---------------------------------------------------------------------------
   BLOCO 4 - Historico: queries que mais pediram memoria desde o restart
   Ajuda a achar o padrao fora do momento do incidente.
   EXIGE SQL SERVER 2016+ (13.x). Em versoes anteriores este bloco falha com
   "Invalid column name 'total_grant_kb'" -- basta remove-lo.
   --------------------------------------------------------------------------- */
SELECT TOP (20)
    execucoes            = qs.execution_count,
    concessao_media_mb   = qs.total_grant_kb      / NULLIF(qs.execution_count,0) / 1024.0,
    concessao_maxima_mb  = qs.max_grant_kb        / 1024.0,
    uso_medio_mb         = qs.total_used_grant_kb / NULLIF(qs.execution_count,0) / 1024.0,
    uso_maximo_mb        = qs.max_used_grant_kb   / 1024.0,
    desperdicio_pct      = CASE WHEN qs.total_grant_kb > 0
                                THEN 100.0 * (qs.total_grant_kb - qs.total_used_grant_kb)
                                     / qs.total_grant_kb END,
    duracao_media_ms     = qs.total_elapsed_time  / NULLIF(qs.execution_count,0) / 1000.0,
    qs.last_execution_time,
    comando              = SUBSTRING(
                               t.text,
                               (qs.statement_start_offset / 2) + 1,
                               ((CASE qs.statement_end_offset
                                     WHEN -1 THEN DATALENGTH(t.text)
                                     ELSE qs.statement_end_offset
                                 END - qs.statement_start_offset) / 2) + 1),
    plano                = p.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle)    AS t
OUTER APPLY sys.dm_exec_query_plan(qs.plan_handle) AS p
WHERE qs.total_grant_kb > 0
ORDER BY qs.max_grant_kb DESC;

/* ===========================================================================
   COMO LER O RESULTADO

   BLOCO 2 com linhas 'NA FILA'
       Ha fila por concessao de memoria. As sessoes em espera aparecem com
       wait_type RESOURCE_SEMAPHORE. Enquanto a fila existir, o sistema inteiro
       fica lento -- inclusive queries pequenas.

   desperdicio_pct alto (acima de 50%)
       A query pediu muito mais do que usou. Isso NAO se corrige com mais RAM:
       corrige-se com ESTIMATIVA melhor.
         1. atualizar estatisticas: ../performance/estatisticas-desatualizadas.md
         2. eliminar conversao implicita de tipo no predicado
         3. revisar variavel de tabela grande (estimativa de 1 linha)
         4. revisar funcao escalar em predicado

   max server memory no valor padrao em servidor dedicado
       O SQL Server tentara usar praticamente toda a memoria da maquina e
       competira com o sistema operacional. Defina um teto explicito,
       reservando memoria para o SO e para outros servicos da maquina.

   Page life expectancy caindo de forma abrupta e sustentada
       Pressao real no buffer pool. Mas confirme antes se a causa nao e uma
       query varrendo tabela inteira -- que e o caso mais comum e se resolve
       com indice, nao com memoria.
   =========================================================================== */
