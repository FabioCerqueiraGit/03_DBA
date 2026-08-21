/* ===========================================================================
   NOME       : encontrar-indices-duplicados-e-redundantes.sql
   OBJETIVO   : Encontrar indices que sao COPIA EXATA de outro, e indices
                REDUNDANTES cuja chave e apenas um prefixo da chave de outro
                indice mais completo.

   COMPATIBILIDADE : SQL Server 2012+ (11.x). Azure SQL Database: sim.
   IMPACTO         : Nenhum para consultar. ALTO para aplicar.
   PERMISSOES      : VIEW DEFINITION no banco.
   TEMPO ESTIMADO  : 1 a 10 segundos.
   ESCOPO          : BANCO CORRENTE. Execute apos USE [<BANCO>].

   POR QUE IMPORTA : indice duplicado nao traz nenhum ganho de leitura -- o
                otimizador usa apenas um deles -- e cobra o preco INTEIRO em
                cada INSERT, UPDATE e DELETE, alem de espaco em disco, em
                backup e no buffer pool.

                Duplicidade quase sempre nasce de indices criados as pressas
                durante incidentes, um por vez, sem olhar o que ja existia.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#Indices') IS NOT NULL DROP TABLE #Indices;

/* Monta, para cada indice, a lista ordenada de colunas-chave e a lista de
   colunas incluidas. A ordem das CHAVES importa e e preservada; a ordem das
   colunas INCLUDE nao importa, por isso e normalizada alfabeticamente. */
SELECT
    i.object_id,
    i.index_id,
    tabela          = QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name),
    indice          = i.name,
    tipo            = i.type_desc,
    i.is_unique,
    i.is_primary_key,
    i.is_unique_constraint,
    i.has_filter,
    filtro          = i.filter_definition,
    chaves = ISNULL(STUFF((
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
    incluidas = ISNULL(STUFF((
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
    tamanho_mb = (SELECT CAST(SUM(ps.used_page_count) * 8.0 / 1024 AS DECIMAL(18,2))
                  FROM sys.dm_db_partition_stats AS ps
                  WHERE ps.object_id = i.object_id
                    AND ps.index_id  = i.index_id)
INTO #Indices
FROM sys.indexes AS i
INNER JOIN sys.objects AS o
        ON o.object_id = i.object_id
WHERE o.type = 'U'
  AND o.is_ms_shipped = 0
  AND i.type IN (1, 2)             /* clusterizado e nao clusterizado */
  AND i.is_hypothetical = 0
  AND i.name IS NOT NULL;


/* ---------------------------------------------------------------------------
   BLOCO 1 - DUPLICADOS EXATOS
   Mesma tabela, mesmas chaves na mesma ordem e mesmas colunas incluidas.
   Nao ha justificativa tecnica para manter os dois.
   --------------------------------------------------------------------------- */
SELECT
    classificacao   = 'DUPLICADO EXATO',
    a.tabela,
    indice_a        = a.indice,
    indice_b        = b.indice,
    chaves          = a.chaves,
    incluidas       = a.incluidas,
    tamanho_a_mb    = a.tamanho_mb,
    tamanho_b_mb    = b.tamanho_mb,
    espaco_recuperavel_mb = b.tamanho_mb,
    unico_a         = a.is_unique,
    unico_b         = b.is_unique,
    pk_a            = a.is_primary_key,
    pk_b            = b.is_primary_key,
    recomendacao = CASE
        WHEN b.is_primary_key = 1 OR b.is_unique_constraint = 1
            THEN 'Manter o B (sustenta constraint). Avaliar remover o A.'
        WHEN a.is_primary_key = 1 OR a.is_unique_constraint = 1
            THEN 'Manter o A (sustenta constraint). Avaliar remover o B.'
        WHEN a.is_unique = 1 AND b.is_unique = 0
            THEN 'Manter o A (unico). Avaliar remover o B.'
        WHEN b.is_unique = 1 AND a.is_unique = 0
            THEN 'Manter o B (unico). Avaliar remover o A.'
        ELSE 'Manter um dos dois. Confira o uso de cada um antes de decidir.'
    END,
    comando_para_revisar =
        'DROP INDEX ' + QUOTENAME(b.indice) + ' ON ' + b.tabela
        + '; -- conferir uso antes de executar'
FROM #Indices AS a
INNER JOIN #Indices AS b
        ON b.object_id = a.object_id
       AND b.index_id  > a.index_id          /* evita listar o par duas vezes */
       AND b.chaves    = a.chaves
       AND b.incluidas = a.incluidas
       AND ISNULL(b.filtro, '') = ISNULL(a.filtro, '')
ORDER BY b.tamanho_mb DESC;


/* ---------------------------------------------------------------------------
   BLOCO 2 - REDUNDANTES POR PREFIXO
   A chave do indice A e um PREFIXO da chave do indice B.
   Um indice sobre (Cliente) e redundante diante de um indice sobre
   (Cliente, Data): o segundo atende as mesmas buscas do primeiro.
   --------------------------------------------------------------------------- */
SELECT
    classificacao   = 'REDUNDANTE POR PREFIXO',
    a.tabela,
    indice_menor    = a.indice,
    chaves_menor    = a.chaves,
    incluidas_menor = a.incluidas,
    indice_maior    = b.indice,
    chaves_maior    = b.chaves,
    incluidas_maior = b.incluidas,
    tamanho_menor_mb = a.tamanho_mb,
    espaco_recuperavel_mb = a.tamanho_mb,
    a_e_unico       = a.is_unique,
    a_e_pk          = a.is_primary_key,
    observacao = CASE
        WHEN a.is_primary_key = 1 OR a.is_unique_constraint = 1
            THEN 'NAO REMOVER: sustenta chave primaria ou constraint de unicidade'
        WHEN a.is_unique = 1
            THEN 'CUIDADO: e unico. Remover altera a garantia de unicidade'
        WHEN a.incluidas <> '' AND a.incluidas <> b.incluidas
            THEN 'CUIDADO: o menor tem INCLUDE proprio. Consolidar antes de remover'
        ELSE 'Candidato a remocao: o indice maior cobre as mesmas buscas'
    END,
    comando_para_revisar =
        'DROP INDEX ' + QUOTENAME(a.indice) + ' ON ' + a.tabela
        + '; -- so apos confirmar o uso'
FROM #Indices AS a
INNER JOIN #Indices AS b
        ON b.object_id = a.object_id
       AND b.index_id <> a.index_id
       AND LEN(b.chaves) > LEN(a.chaves)
       /* prefixo verdadeiro: b.chaves comeca com a.chaves seguido de virgula */
       AND LEFT(b.chaves, LEN(a.chaves) + 2) = a.chaves + ', '
       AND ISNULL(b.filtro, '') = ISNULL(a.filtro, '')
WHERE a.chaves <> ''
ORDER BY a.tamanho_mb DESC;


/* ---------------------------------------------------------------------------
   BLOCO 3 - Panorama por tabela
   Tabelas com muitos indices sao candidatas naturais a consolidacao.
   --------------------------------------------------------------------------- */
SELECT
    tabela              = i.tabela,
    total_de_indices    = COUNT(*),
    nao_clusterizados   = SUM(CASE WHEN i.tipo = 'NONCLUSTERED' THEN 1 ELSE 0 END),
    espaco_indices_mb   = SUM(CASE WHEN i.index_id > 1 THEN i.tamanho_mb ELSE 0 END),
    espaco_dados_mb     = SUM(CASE WHEN i.index_id <= 1 THEN i.tamanho_mb ELSE 0 END),
    alerta = CASE
        WHEN SUM(CASE WHEN i.tipo = 'NONCLUSTERED' THEN 1 ELSE 0 END) >= 10
            THEN 'MUITOS INDICES - cada escrita paga por todos eles'
        WHEN SUM(CASE WHEN i.index_id > 1 THEN i.tamanho_mb ELSE 0 END)
             > SUM(CASE WHEN i.index_id <= 1 THEN i.tamanho_mb ELSE 0 END)
            THEN 'INDICES OCUPAM MAIS QUE OS DADOS - avaliar consolidacao'
        ELSE 'ok'
    END
FROM #Indices AS i
GROUP BY i.tabela
HAVING COUNT(*) > 1
ORDER BY SUM(CASE WHEN i.index_id > 1 THEN i.tamanho_mb ELSE 0 END) DESC;

DROP TABLE #Indices;

/* ===========================================================================
   COMO DECIDIR

   BLOCO 1 (duplicado exato)
       Decisao facil: mantenha um. A prioridade e sempre:
         1. o que sustenta PRIMARY KEY ou UNIQUE constraint;
         2. o unico;
         3. o mais usado (confira em encontrar-indices-nao-utilizados.sql).

   BLOCO 2 (redundante por prefixo)
       Decisao com nuance. O indice maior atende as mesmas BUSCAS do menor,
       mas nao e identico:
         - o menor e mais estreito, logo tem menos paginas e uma varredura
           completa dele custa menos I/O;
         - se o menor for UNICO, ele carrega uma garantia de integridade que
           o maior nao tem.
       Na pratica, em tabelas com escrita intensa, remover o menor costuma
       compensar. Em tabelas quase somente de leitura, o ganho e pequeno.

   BLOCO 3 (panorama)
       Tabela com dez ou mais indices nao clusterizados quase sempre e
       resultado de anos de correcoes pontuais. Vale uma revisao completa dos
       indices dessa tabela, nao ajustes isolados.

   SEMPRE, ANTES DE REMOVER
       1. guarde a definicao completa do indice;
       2. prefira ALTER INDEX ... DISABLE (reversivel) a DROP INDEX;
       3. observe por um ciclo de negocio completo;
       4. so entao remova.

   LIMITACOES CONHECIDAS DESTE SCRIPT
       - indices FILTRADOS so sao comparados entre si quando o filtro e
         textualmente identico. Filtros equivalentes escritos de formas
         diferentes nao sao detectados;
       - indices columnstore, XML, espaciais e full-text nao sao analisados;
       - a comparacao de prefixo e textual: um indice sobre (ClienteId) e
         detectado como prefixo de (ClienteId, Data), mas nao de
         (Data, ClienteId) -- e corretamente, porque a ordem das chaves
         determina o que o indice consegue buscar.
   =========================================================================== */
