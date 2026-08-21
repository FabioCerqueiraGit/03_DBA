/* ===========================================================================
   NOME       : tamanho-das-tabelas.sql
   OBJETIVO   : Listar todas as tabelas do banco por espaco ocupado, separando
                o que sao DADOS do que sao INDICES do que e espaco RESERVADO
                e nao utilizado.

   COMPATIBILIDADE : SQL Server 2012+ (11.x). Azure SQL Database: sim.
   IMPACTO         : Nenhum. Somente leitura sobre catalogo e DMVs.
                     Nao usa sp_spaceused, que precisa ser chamado tabela a
                     tabela e nao permite ordenar o resultado.
   PERMISSOES      : VIEW DATABASE STATE.
   TEMPO ESTIMADO  : < 5 segundos.
   ESCOPO          : BANCO CORRENTE. Execute apos USE [<BANCO>].

   RESPONDE A      : "Por que o banco esta crescendo?"
                     "Quais tabelas ocupam mais espaco?"
                     "Os indices ocupam mais que os dados?"

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

SELECT
    tabela            = QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name),
    linhas            = MAX(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count END),

    total_mb          = CAST(SUM(ps.reserved_page_count) * 8.0 / 1024 AS DECIMAL(18,2)),
    dados_mb          = CAST(SUM(CASE WHEN ps.index_id IN (0,1)
                                      THEN ps.used_page_count ELSE 0 END)
                             * 8.0 / 1024 AS DECIMAL(18,2)),
    indices_mb        = CAST(SUM(CASE WHEN ps.index_id > 1
                                      THEN ps.used_page_count ELSE 0 END)
                             * 8.0 / 1024 AS DECIMAL(18,2)),
    /* Espaco reservado e ainda nao usado. Valor muito alto costuma ser
       resultado de DELETE massivo sem reaproveitamento. */
    reservado_nao_usado_mb = CAST((SUM(ps.reserved_page_count) - SUM(ps.used_page_count))
                                  * 8.0 / 1024 AS DECIMAL(18,2)),

    /* Quanto esta tabela representa do banco inteiro */
    percentual_do_banco = CAST(100.0 * SUM(ps.reserved_page_count)
                               / NULLIF(SUM(SUM(ps.reserved_page_count)) OVER (), 0)
                               AS DECIMAL(5,2)),

    /* Um numero muito util para dimensionamento e para estimar crescimento */
    bytes_por_linha   = CASE
                            WHEN MAX(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count END) > 0
                            THEN CAST(SUM(ps.used_page_count) * 8192.0
                                 / MAX(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count END)
                                 AS DECIMAL(18,2))
                        END,

    qtde_indices      = COUNT(DISTINCT CASE WHEN ps.index_id > 1 THEN ps.index_id END),
    tem_lob           = CASE WHEN SUM(ps.lob_used_page_count) > 0 THEN 'sim' ELSE 'nao' END,
    lob_mb            = CAST(SUM(ps.lob_used_page_count) * 8.0 / 1024 AS DECIMAL(18,2)),

    observacao = CASE
        WHEN SUM(CASE WHEN ps.index_id > 1 THEN ps.used_page_count ELSE 0 END)
           > SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.used_page_count ELSE 0 END)
            THEN 'INDICES OCUPAM MAIS QUE OS DADOS - revisar duplicidade'
        WHEN (SUM(ps.reserved_page_count) - SUM(ps.used_page_count)) * 8.0 / 1024 > 1024
            THEN 'MUITO ESPACO RESERVADO E NAO USADO - possivel DELETE massivo'
        WHEN MAX(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count END) = 0
            THEN 'TABELA VAZIA'
        ELSE NULL
    END

FROM sys.dm_db_partition_stats AS ps
INNER JOIN sys.objects AS o
        ON o.object_id = ps.object_id
WHERE o.type = 'U'
  AND o.is_ms_shipped = 0
GROUP BY o.schema_id, o.name
ORDER BY SUM(ps.reserved_page_count) DESC;

/* ===========================================================================
   COMO LER O RESULTADO

   Poucas tabelas concentram quase todo o banco
       E o padrao normal. Concentre a atencao de indices, particionamento e
       arquivamento nessas tabelas -- otimizar as pequenas nao muda nada.

   indices_mb maior que dados_mb
       Indice demais. Va para ../indexes/encontrar-indices-duplicados-e-redundantes.sql
       e ../indexes/encontrar-indices-nao-utilizados.sql. Alem do disco, esses
       indices disputam espaco no buffer pool com os dados reais.

   reservado_nao_usado_mb alto
       A tabela ja foi maior. Houve DELETE massivo e o espaco continua alocado
       (o que e correto: sera reaproveitado). Isso NAO e motivo para SHRINK.
       Veja ../administracao/shrink-quando-nao-usar.md

   bytes_por_linha inesperadamente alto
       Revise os tipos de dados. Suspeitos frequentes:
         - NVARCHAR onde VARCHAR bastaria (o dobro de bytes por caractere);
         - CHAR(200) em vez de VARCHAR(200);
         - colunas LOB (NVARCHAR(MAX), VARBINARY(MAX)) armazenando arquivos
           que poderiam estar fora do banco.

   PARA ESTIMAR CRESCIMENTO FUTURO
       Combine 'bytes_por_linha' com a taxa de insercao diaria da tabela.
       Um numero simples como este vale mais em uma reuniao de capacidade do
       que qualquer estimativa por intuicao.

   PARA ENTENDER O CRESCIMENTO PASSADO
       Colete este script periodicamente e guarde o historico em uma tabela
       propria. Sem serie historica nao ha como responder "desde quando esta
       crescendo" -- e essa e sempre a primeira pergunta.
   =========================================================================== */
