/* ===========================================================================
   NOME       : tamanho-dos-indices.sql
   OBJETIVO   : Detalhar o espaco ocupado por CADA indice, com as colunas que o
                compoem e o uso registrado, para decidir o que consolidar ou
                remover.

   COMPATIBILIDADE : SQL Server 2012+ (11.x). Azure SQL Database: sim.
   IMPACTO         : Nenhum. Somente leitura.
   PERMISSOES      : VIEW DATABASE STATE e VIEW DEFINITION.
   TEMPO ESTIMADO  : 1 a 10 segundos.
   ESCOPO          : BANCO CORRENTE. Execute apos USE [<BANCO>].

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

SELECT
    tabela          = QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name),
    indice          = ISNULL(i.name, '(heap)'),
    tipo            = i.type_desc,
    i.is_unique,
    i.is_primary_key,
    i.has_filter,
    filtro          = i.filter_definition,

    tamanho_mb      = CAST(SUM(ps.used_page_count) * 8.0 / 1024 AS DECIMAL(18,2)),
    reservado_mb    = CAST(SUM(ps.reserved_page_count) * 8.0 / 1024 AS DECIMAL(18,2)),
    linhas          = MAX(ps.row_count),

    /* Quanto este indice representa do total ocupado pela tabela */
    pct_da_tabela   = CAST(100.0 * SUM(ps.used_page_count)
                           / NULLIF(SUM(SUM(ps.used_page_count))
                                    OVER (PARTITION BY o.object_id), 0)
                           AS DECIMAL(5,2)),

    colunas_chave = ISNULL(STUFF((
            SELECT ', ' + c.name
                   + CASE WHEN ic.is_descending_key = 1 THEN ' DESC' ELSE '' END
            FROM sys.index_columns AS ic
            INNER JOIN sys.columns AS c
                    ON c.object_id = ic.object_id
                   AND c.column_id = ic.column_id
            WHERE ic.object_id = i.object_id
              AND ic.index_id  = i.index_id
              AND ic.is_included_column = 0
            ORDER BY ic.key_ordinal
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''), ''),

    colunas_incluidas = ISNULL(STUFF((
            SELECT ', ' + c.name
            FROM sys.index_columns AS ic
            INNER JOIN sys.columns AS c
                    ON c.object_id = ic.object_id
                   AND c.column_id = ic.column_id
            WHERE ic.object_id = i.object_id
              AND ic.index_id  = i.index_id
              AND ic.is_included_column = 1
            ORDER BY c.name
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, ''), ''),

    leituras        = ISNULL(MAX(ius.user_seeks),0) + ISNULL(MAX(ius.user_scans),0)
                      + ISNULL(MAX(ius.user_lookups),0),
    manutencoes     = ISNULL(MAX(ius.user_updates), 0),

    avaliacao = CASE
        WHEN i.index_id > 1
         AND ISNULL(MAX(ius.user_seeks),0) + ISNULL(MAX(ius.user_scans),0)
           + ISNULL(MAX(ius.user_lookups),0) = 0
         AND SUM(ps.used_page_count) * 8.0 / 1024 > 100
            THEN 'GRANDE E SEM LEITURA - forte candidato a remocao'
        WHEN i.index_id > 1
         AND SUM(ps.used_page_count) * 8.0 / 1024
             > 0.5 * (SELECT SUM(ps2.used_page_count) * 8.0 / 1024
                      FROM sys.dm_db_partition_stats AS ps2
                      WHERE ps2.object_id = o.object_id
                        AND ps2.index_id IN (0,1))
            THEN 'INDICE QUASE DO TAMANHO DA TABELA - INCLUDE provavelmente excessivo'
        ELSE NULL
    END

FROM sys.dm_db_partition_stats AS ps
INNER JOIN sys.indexes AS i
        ON i.object_id = ps.object_id
       AND i.index_id  = ps.index_id
INNER JOIN sys.objects AS o
        ON o.object_id = i.object_id
LEFT JOIN sys.dm_db_index_usage_stats AS ius
       ON ius.object_id   = i.object_id
      AND ius.index_id    = i.index_id
      AND ius.database_id = DB_ID()
WHERE o.type = 'U'
  AND o.is_ms_shipped = 0
GROUP BY o.object_id, o.schema_id, o.name, i.object_id, i.index_id, i.name,
         i.type_desc, i.is_unique, i.is_primary_key, i.has_filter,
         i.filter_definition
ORDER BY SUM(ps.used_page_count) DESC;

/* ===========================================================================
   COMO LER O RESULTADO

   'GRANDE E SEM LEITURA'
       Indice ocupando espaco relevante e sem nenhuma leitura desde o restart.
       Confirme o uptime e o ciclo de negocio em
       ../indexes/encontrar-indices-nao-utilizados.sql antes de remover.

   'INDICE QUASE DO TAMANHO DA TABELA'
       Quase sempre um INCLUDE exagerado -- alguem incluiu praticamente todas
       as colunas para "cobrir" uma query. O resultado e uma segunda copia da
       tabela, que precisa ser mantida a cada escrita e disputa buffer pool.
       Revise se a query realmente precisa de todas aquelas colunas.

   pct_da_tabela
       Mostra a distribuicao do espaco entre os indices de cada tabela. Um
       indice nao clusterizado com percentual proximo ao dos dados merece
       explicacao.

   colunas_chave em branco
       Heap (tabela sem indice clusterizado). Heaps tem lugar em cenarios de
       carga em massa, mas em tabela transacional costumam ser resultado de
       modelagem incompleta -- e sofrem com forwarded records.

   INDICES FILTRADOS
       has_filter = 1 indica indice filtrado: menor e mais barato, porem so e
       usado quando o predicado da query e compativel com o filtro. Verifique
       na coluna 'leituras' se ele esta realmente sendo aproveitado.
   =========================================================================== */
