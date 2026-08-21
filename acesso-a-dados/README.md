# Acesso a dados

> Quatro formas diferentes de falar com o mesmo SQL Server. Cada uma com armadilhas
> próprias, e todas apoiadas em ADO.NET no fundo.

---

## Documentos

### ADO.NET — a base de tudo

| Documento | Assunto |
|---|---|
| [`ado-net/ado-net-fundamentos-seguros.md`](ado-net/ado-net-fundamentos-seguros.md) | Driver, connection string, parametrização, transações, erros transitórios |
| [`ado-net/connection-pool-esgotado.md`](ado-net/connection-pool-esgotado.md) | "Timeout expired" ao abrir conexão — as cinco causas |
| [`ado-net/timeout-de-comando-vs-conexao.md`](ado-net/timeout-de-comando-vs-conexao.md) | `CommandTimeout` x `Connect Timeout`, e a transação que fica aberta |

### Dapper

| Documento | Assunto |
|---|---|
| [`dapper/dapper-receitas-essenciais.md`](dapper/dapper-receitas-essenciais.md) | Consultas, `splitOn`, `QueryMultiple`, transações, `SqlBulkCopy` |

### Entity Framework

| Documento | Assunto |
|---|---|
| [`entity-framework-core/ef-core-performance.md`](entity-framework-core/ef-core-performance.md) | `N+1`, explosão cartesiana, tracking, operações em massa, migrations |
| [`entity-framework-6/ef6-troubleshooting.md`](entity-framework-6/ef6-troubleshooting.md) | Lazy loading ligado por padrão, `AutoDetectChanges`, erros clássicos |

---

## Como escolher

| Cenário | Escolha |
|---|---|
| CRUD sobre modelo rico, com relacionamentos | **EF Core** |
| Consulta complexa, relatório, alto volume de leitura | **Dapper** |
| Carga em massa | **`SqlBulkCopy`** |
| Controle total, ou dependência mínima | **ADO.NET puro** |
| Sistema legado em .NET Framework | **EF6** ou ADO.NET — e Dapper onde doer |

Misturar é legítimo e comum: EF Core para escrita, Dapper para as consultas críticas.

---

## Os cinco erros que aparecem em toda auditoria

1. **`SqlConnection` sem `using`** → pool esgotado, e a mensagem culpa o banco.
2. **`AddWithValue`** → `NVARCHAR` contra coluna `VARCHAR` → conversão implícita → o índice
   deixa de ser usado.
3. **`N+1`** → centenas de queries baratas que somadas dominam a CPU do servidor.
4. **Transação envolvendo chamada HTTP** → locks retidos enquanto se espera um terceiro.
5. **`CommandTimeout = 0`** → uma query travada leva a aplicação inteira junto.

Os cinco aparecem do lado do banco em
[`../sql-server/monitoramento/sessoes-e-requests-em-execucao.sql`](../sql-server/monitoramento/sessoes-e-requests-em-execucao.sql)
e em
[`../sql-server/performance/queries-que-mais-consomem-cpu.sql`](../sql-server/performance/queries-que-mais-consomem-cpu.sql).

---

## O ajuste que torna todo diagnóstico futuro possível

```text
Server=<SERVIDOR>;Database=<BANCO>;...;Application Name=<NOME-DO-SISTEMA>
```

Sem `Application Name`, toda conexão chega ao SQL Server como
`.Net SqlClient Data Provider` e nenhum diagnóstico consegue dizer **qual** sistema causou
o problema. Custa uma linha de configuração.

---

**Criado por Fábio Cerqueira**
