# Estratégias de deployment e rollback — inclusive do banco

> Como colocar uma versão nova no ar sem ficar refém do "deu ruim, e agora?" — com atenção
> especial ao ponto que quase todo plano de rollback esquece: o banco de dados.

| | |
|---|---|
| **Compatibilidade** | Aplicável a .NET Framework em IIS e a .NET 6+ em IIS, Linux ou contêiner. |
| **Impacto** | **Alto.** Este documento trata de mudanças em produção. |
| **Pré-requisito** | Backup validado e restaurável. Ver [`sql-server/administracao/`](../../sql-server/administracao/). |

---

## Problema

A pergunta "temos rollback?" quase sempre recebe a resposta "sim, é só voltar a versão anterior da
aplicação". Isso é meia verdade. Voltar binário é fácil. O que trava o rollback de verdade é:

- a migração de banco que rodou junto e apagou uma coluna;
- o cache distribuído que já está populado com o formato novo de serialização;
- a mensagem em fila publicada no contrato novo e ainda não consumida;
- a integração que já notificou o parceiro de que o pedido foi processado;
- o arquivo de configuração que ninguém versionou e que foi editado à mão no servidor.

Rollback não é um botão. É uma propriedade que o deployment precisa **ter sido projetado** para ter.

---

## A regra que resolve 80% do problema

> **Toda alteração de banco deve ser retrocompatível com a versão anterior da aplicação.**

Se a versão N-1 da aplicação continua funcionando contra o esquema novo, o rollback da aplicação é
trivial e independente. Se não continua, você acoplou o rollback da aplicação ao rollback do banco —
e rollback de banco com dado novo já gravado é, na melhor das hipóteses, doloroso.

Isso implica separar toda mudança destrutiva em pelo menos dois deployments.

### Padrão *expand / contract*

**Renomear a coluna `Nome` para `NomeCompleto`:**

| Deployment | Banco | Aplicação |
|---|---|---|
| 1 — *expand* | `ADD NomeCompleto`; trigger ou dupla escrita mantém as duas sincronizadas | Escreve nas duas colunas, lê de `Nome` |
| 2 | — | Escreve nas duas, lê de `NomeCompleto` |
| 3 | Backfill concluído e verificado | Escreve e lê só em `NomeCompleto` |
| 4 — *contract* | `DROP COLUMN Nome` | — |

Parece burocrático. É a diferença entre poder voltar atrás em qualquer um dos quatro passos e ter
que restaurar backup no meio do expediente.

### Mudanças e sua retrocompatibilidade

| Mudança | Retrocompatível? | Observação |
|---|---|---|
| `ADD COLUMN` **NULL** ou com default | ✅ | O caminho seguro por padrão |
| `ADD COLUMN NOT NULL` sem default | ❌ | `INSERT` da versão antiga quebra |
| `ADD COLUMN NOT NULL` **com** default | ⚠️ | Seguro para a aplicação. No SQL Server 2012+ Enterprise é operação de metadado; nas demais edições reescreve a tabela inteira |
| `DROP COLUMN` | ❌ | Só depois que nenhuma versão em produção a referencia |
| Renomear coluna ou tabela | ❌ | Use expand/contract |
| Alterar tipo (`VARCHAR(50)` → `VARCHAR(100)`) | ✅ | Ampliar é seguro; reduzir não é |
| `CREATE INDEX` | ⚠️ | Seguro para a aplicação, mas bloqueia. `ONLINE = ON` é recurso de edição Enterprise — confira a matriz de edições da sua versão antes de contar com ele |
| `DROP INDEX` | ⚠️ | A aplicação funciona; o plano de execução pode degradar catastroficamente |
| Alterar stored procedure adicionando parâmetro **com default** | ✅ | Chamadas antigas continuam válidas |
| Alterar stored procedure mudando colunas do resultado | ❌ | Quebra o mapeamento da versão antiga |
| `ADD CONSTRAINT` com `WITH CHECK` | ❌ | A versão antiga pode gravar dado que viola a regra nova |

---

## Estratégias de deployment

### 1. Recreate (parar, trocar, subir)

Para a aplicação, substitui os arquivos, sobe.

**Quando usar:** sistema interno com janela de manutenção aceita, aplicação com estado difícil de
duplicar, ou quando a mudança de banco não é retrocompatível de jeito nenhum.

**Quando NÃO usar:** aplicação com SLA de disponibilidade, ou quando o tempo de subida
(*cold start*, aquecimento de cache, JIT) é longo o suficiente para o usuário perceber.

**Rollback:** restaurar os arquivos da versão anterior. Sempre mantenha a pasta da versão anterior
no servidor — não confie em ter que rebaixar um artefato do repositório às 3 da manhã.

### 2. Blue-green

Dois ambientes idênticos. O tráfego aponta para um; a versão nova sobe no outro; valida-se; o
tráfego troca.

**Rollback:** apontar o tráfego de volta. É o rollback mais rápido que existe.

No IIS isso costuma ser feito com duas pastas físicas e a troca do *physical path* do site, ou com
dois sites e a troca do binding. No Azure App Service, é o *deployment slot* com *swap* — que tem
a vantagem de aquecer a aplicação antes da troca.

**Custo:** duas vezes a infraestrutura, e o banco continua sendo um só e compartilhado pelos dois
lados. **Blue-green não resolve o rollback de banco** — só o da aplicação. É exatamente por isso
que a regra da retrocompatibilidade continua valendo.

### 3. Rolling / canário

A versão nova sobe em uma parte das instâncias. Observa-se erro e latência. Se estiver bom,
avança; se não, recua.

**Requisito não negociável:** durante a transição, **duas versões da aplicação rodam ao mesmo
tempo contra o mesmo banco**. Se o esquema não for retrocompatível, isso não é uma opção — é uma
falha planejada.

**Requisito prático:** observabilidade que permita comparar a taxa de erro da versão nova contra a
antiga. Sem isso, canário é só um deployment mais lento. Ver
[`dotnet/logging/`](../../dotnet/logging/).

### 4. Feature flag

O código novo vai para produção desligado. O deployment e a ativação viram dois eventos separados.

**Vantagem real:** o rollback deixa de ser um deployment. Desligar a flag é instantâneo e não
depende de pipeline, de aprovação nem de IIS reiniciando.

**Custo:** cada flag é um caminho a mais no código, e flag esquecida vira dívida técnica com
comportamento imprevisível. Toda flag precisa de data de remoção combinada.

---

## Migração de banco no pipeline

### Não use `Database.Migrate()` na inicialização da aplicação

É comum ver isso em `Program.cs`:

```csharp
// NAO faca isso em producao
using var escopo = app.Services.CreateScope();
escopo.ServiceProvider.GetRequiredService<MeuDbContext>().Database.Migrate();
```

Problemas:

- **Corrida.** Com múltiplas instâncias (rolling, canário, App Service escalado), várias tentam
  migrar ao mesmo tempo.
- **Privilégio.** A aplicação passa a precisar de permissão de DDL em produção o tempo todo, e não
  só durante a migração.
- **Sem rollback.** Se a migração falhar no meio, a aplicação não sobe e você fica sem
  aplicação **e** com banco em estado intermediário.
- **Sem revisão.** Ninguém olhou o SQL que vai rodar.

### Faça: gere o script, revise, aplique como passo próprio

```bash
# EF Core — gera script idempotente cobrindo da migracao atual em diante
dotnet ef migrations script --idempotent --output ./artefatos/migracao.sql

# EF Core — script de um ponto especifico ate o mais recente
dotnet ef migrations script <MigracaoAnterior> <MigracaoAlvo> --output ./artefatos/migracao.sql
```

`--idempotent` gera um script que verifica a tabela `__EFMigrationsHistory` antes de cada bloco,
então ele pode ser executado mais de uma vez sem efeito duplicado.

O script gerado **deve ser lido antes de rodar**. Procure especificamente por:

- `DROP COLUMN`, `DROP TABLE`, `DROP CONSTRAINT`;
- `ALTER COLUMN` que reduz tamanho ou muda tipo;
- `CREATE INDEX` sem `ONLINE = ON` em tabela grande;
- `UPDATE` de backfill sem lote (uma transação única em tabela de milhões de linhas mantém
  bloqueio e faz o transaction log crescer — ver
  [`sql-server/troubleshooting/`](../../sql-server/troubleshooting/)).

Backfill grande vai em lotes:

```sql
-- Backfill em lotes, com pausa entre eles.
-- Cada lote e uma transacao curta: o log tem chance de truncar entre elas
-- (se o recovery model for FULL, dependendo do backup de log rodando).
WHILE 1 = 1
BEGIN
    UPDATE TOP (5000) dbo.Pedido
       SET NomeCompleto = Nome
     WHERE NomeCompleto IS NULL
       AND Nome IS NOT NULL;

    IF @@ROWCOUNT = 0 BREAK;

    WAITFOR DELAY '00:00:01';
END
```

### Migração para frente, dado preservado

Para todo script de migração, escreva também o **script de compensação** — o que desfaz a mudança
estrutural sem perder dado gravado no intervalo. Se não for possível escrever esse script, isso
por si só é a informação de que a migração não é reversível, e a decisão de aplicá-la precisa
subir de nível.

---

## O que verificar depois do deployment

Deployment não termina quando o pipeline fica verde. Ele termina quando os indicadores voltaram ao
normal.

| Janela | O que olhar |
|---|---|
| Primeiros 5 minutos | Aplicação responde; taxa de HTTP 5xx; log de erro; Application Pool não está reciclando em loop |
| Primeiros 15 minutos | Latência p95 comparada à hora anterior; conexões ativas no SQL Server; sem bloqueio novo |
| Primeira hora | Waits e top queries por CPU — plano de execução novo pode ter degradado; consumo de memória estável (vazamento aparece aqui) |
| Primeiro ciclo de negócio | Jobs, rotinas noturnas, integrações agendadas, fechamento |

Scripts úteis nessa janela:

- [`sql-server/troubleshooting/`](../../sql-server/troubleshooting/) — triagem rápida e bloqueio
- [`sql-server/performance/`](../../sql-server/performance/) — top queries por CPU e por I/O
- [`iis/troubleshooting/`](../../iis/troubleshooting/) — se a aplicação estiver em IIS

---

## Critérios de rollback — decidir antes, não durante

Defina **antes do deployment** o que dispara o rollback. Sob pressão, com gerente ao lado, a
tendência é sempre "vamos esperar mais dez minutos".

Modelo:

```text
Faremos rollback imediato se, nos primeiros 30 minutos:
  - taxa de erro 5xx > 2% por mais de 5 minutos consecutivos; ou
  - latencia p95 acima de 3x a linha de base; ou
  - qualquer erro de integridade de dado; ou
  - qualquer falha na integracao com <SISTEMA-PARCEIRO>.

Responsavel pela decisao: <NOME>
Responsavel pela execucao: <NOME>
Tempo alvo de rollback: 10 minutos
```

O "tempo alvo de rollback" merece atenção: se ninguém nunca cronometrou, o número é chute. Um
rollback ensaiado em homologação é o único que se sabe que funciona.

---

## Quando NÃO fazer rollback

Rollback nem sempre é a resposta certa:

- **Quando já houve escrita no formato novo** e a versão antiga não sabe ler. Voltar aqui gera
  corrupção lógica silenciosa, pior que a indisponibilidade.
- **Quando a falha é externa** (parceiro fora do ar, certificado expirado, DNS). Rollback não
  conserta e ainda adiciona uma variável.
- **Quando o *forward fix* é comprovadamente menor** — uma linha de configuração, uma flag, um
  índice faltando. Mas cuidado: "é só uma linha" às 3 da manhã costuma ser o começo do segundo
  incidente.

Se você não sabe qual dos dois caminhos é menor, o rollback é o caminho conhecido. Prefira o
conhecido.

---

## Cuidados

- **`web.config` e `appsettings.json` editados à mão no servidor.** Alguém ajustou o timeout em
  produção seis meses atrás e não versionou. O deployment sobrescreve e o problema antigo volta —
  agora sem ninguém lembrar o porquê. Trate configuração como código ou, no mínimo, tire diff dos
  arquivos do servidor antes de substituí-los.
- **Cache distribuído com objeto serializado.** Se o formato mudou, o rollback encontra cache
  envenenado. Versione a chave de cache (`pedido:v2:{id}`) para que versões diferentes não
  disputem a mesma entrada.
- **Fila com mensagem em contrato novo.** Consumidor antigo pode falhar em série e mandar tudo
  para dead-letter. Consumidor deve ignorar campo desconhecido, não rejeitar.
- **`app_offline.htm` no IIS** derruba o Application Pool de forma limpa e é o jeito correto de
  parar uma aplicação ASP.NET durante a troca de arquivos. Sem ele, arquivo em uso impede a cópia.
- **Deployment na sexta-feira à tarde** não é proibido por superstição. É que a janela de
  observação é justamente a menor da semana.

---

## Checklist

Ver também o [checklist de deployment de aplicação .NET](../../checklists/).

- [ ] Artefato construído uma única vez e promovido entre ambientes.
- [ ] Script de migração gerado, **lido** e revisado por outra pessoa.
- [ ] Migração retrocompatível com a versão N-1 da aplicação.
- [ ] Backup do banco recente e **testado** — backup não restaurado é hipótese, não backup.
- [ ] Backfill em lotes, com impacto em log estimado.
- [ ] Versão anterior da aplicação disponível para restauração imediata.
- [ ] Configuração do servidor comparada com a versionada antes de sobrescrever.
- [ ] Critérios de rollback escritos, com responsável nomeado.
- [ ] Tempo de rollback ensaiado ao menos uma vez em homologação.
- [ ] Plano de observação definido para as primeiras 24 horas.
- [ ] Integrações e parceiros avisados, se houver mudança de contrato.

---

## Referências

- [Microsoft Learn — `dotnet ef migrations script` (Applying migrations)](https://learn.microsoft.com/ef/core/managing-schemas/migrations/applying)
- [Microsoft Learn — Deployment slots no Azure App Service](https://learn.microsoft.com/azure/app-service/deploy-staging-slots)
- [Microsoft Learn — `ALTER TABLE` (Transact-SQL)](https://learn.microsoft.com/sql/t-sql/statements/alter-table-transact-sql)
- [Microsoft Learn — Operações de índice online](https://learn.microsoft.com/sql/relational-databases/indexes/perform-index-operations-online)
- [Microsoft Learn — `app_offline.htm` no ASP.NET Core / IIS](https://learn.microsoft.com/aspnet/core/host-and-deploy/iis/advanced)

---

**Criado por Fábio Cerqueira**
