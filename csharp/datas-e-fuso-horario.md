# Datas e fuso horário — do C# ao SQL Server

> Relatório com um dia a mais, horário que muda sozinho, data que o banco recusou. Todos têm a
> mesma raiz: um `DateTime` que não sabe de onde veio.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6+ e .NET 6+. `DateOnly`/`TimeOnly` exigem .NET 6+; IANA IDs no Windows também. |
| **Impacto** | Correção de tipo de coluna altera o esquema — ver [`devops/deployment/`](../devops/deployment/estrategias-de-deployment-e-rollback.md). |
| **Contexto** | O Brasil não observa horário de verão desde 2019, mas dados anteriores a essa data observam. |

---

## Problema

`DateTime` não carrega fuso horário. Ele tem um campo `Kind` (`Utc`, `Local`, `Unspecified`) que é
perdido em quase toda serialização e em **toda** ida ao SQL Server — as colunas `DATETIME` e
`DATETIME2` não guardam essa informação.

O resultado é previsível: o valor é gravado em horário local do servidor, lido de volta como
`Unspecified`, tratado como local por uma camada e como UTC por outra. A diferença de três horas
aparece em um relatório meses depois, quando ninguém lembra do código.

E o defeito **não aparece na máquina de quem desenvolve**, porque lá o fuso é o mesmo do usuário.
Aparece no servidor — ou no contêiner Linux configurado em UTC.

---

## Regra 1 — Escolher o tipo certo

| Tipo | Guarda fuso? | Use para |
|---|---|---|
| `DateTimeOffset` | **Sim** (deslocamento) | **Padrão recomendado** para instante em que a origem importa: criação de pedido, log, evento |
| `DateTime` com `Kind = Utc` | Implicitamente UTC | Instante, quando o deslocamento de origem é irrelevante |
| `DateOnly` (.NET 6+) | Não se aplica | Data de nascimento, vencimento, competência. **Não tem hora, logo não tem fuso** |
| `TimeOnly` (.NET 6+) | Não se aplica | Hora de funcionamento, horário de agenda |
| `DateTime` com `Kind = Local` | "Local de quem?" | Evite. É a origem da maior parte dos defeitos |

> **`DateOnly` merece atenção especial.** Data de nascimento guardada como `DateTime` gera o bug
> clássico do "um dia a menos": grava-se `1985-03-12 00:00:00` local, converte-se para UTC ao
> serializar, e a data vira `1985-03-11T21:00:00Z`. O cliente nasceu um dia antes. `DateOnly`
> elimina a categoria — não há hora para converter.

---

## Regra 2 — UTC no armazenamento, local só na apresentação

```csharp
// Captura: sempre com deslocamento explicito
var criadoEm = DateTimeOffset.UtcNow;

// Persistencia: o valor vai em UTC
pedido.CriadoEm = criadoEm;

// Apresentacao: converte no ultimo momento possivel, para o fuso do usuario
var fusoBrasilia = ObterFuso();
var exibicao = TimeZoneInfo.ConvertTime(pedido.CriadoEm, fusoBrasilia);
```

O erro comum é converter cedo demais — gravar já convertido "para facilitar o relatório". Isso
torna impossível saber, depois, se o valor é local ou UTC, e impede atender usuários em fusos
diferentes.

### `DateTime.Now` versus `DateTime.UtcNow`

```csharp
DateTime.Now       // Hora local do SERVIDOR. Muda com o fuso da maquina.
DateTime.UtcNow    // Sempre UTC. Previsivel.
DateTimeOffset.Now // Local + deslocamento explicito.
```

`DateTime.Now` em lógica de negócio é um acoplamento ao fuso do servidor. Quando a aplicação migra
para um contêiner Linux em UTC, o comportamento muda — sem nenhuma alteração de código.

### Torne o relógio uma dependência

Com `DateTime.Now` espalhado, não há como testar regra de vencimento sem mexer no relógio da
máquina.

```csharp
// .NET 8+ traz TimeProvider na propria biblioteca padrao
public sealed class CalculadoraDeVencimento
{
    private readonly TimeProvider _relogio;

    public CalculadoraDeVencimento(TimeProvider relogio) => _relogio = relogio;

    public bool EstaVencido(DateTimeOffset vencimento) =>
        _relogio.GetUtcNow() > vencimento;
}

// Registro: builder.Services.AddSingleton(TimeProvider.System);
// Em teste: FakeTimeProvider (pacote Microsoft.Extensions.TimeProvider.Testing)
```

Em .NET Framework ou .NET anterior ao 8, o equivalente é uma interface própria:

```csharp
public interface IRelogio { DateTimeOffset AgoraUtc { get; } }

public sealed class RelogioDoSistema : IRelogio
{
    public DateTimeOffset AgoraUtc => DateTimeOffset.UtcNow;
}
```

---

## Regra 3 — Fuso horário: identificadores e a armadilha do multiplataforma

```csharp
// Identificador do Windows
var fuso = TimeZoneInfo.FindSystemTimeZoneById("E. South America Standard Time");

// Identificador IANA (Linux, macOS e Windows a partir do .NET 6)
var fuso = TimeZoneInfo.FindSystemTimeZoneById("America/Sao_Paulo");
```

A partir do .NET 6, o Windows também aceita identificadores IANA — **mas com condições**: apenas
se o NLS não estiver habilitado e o modo *globalization invariant* estiver desligado. Linux e
macOS usam a biblioteca ICU.

Isso significa que código que assume um dos dois formatos quebra ao mudar de plataforma — e
quebra com `TimeZoneNotFoundException`, em produção, na primeira conversão.

**Padrão defensivo, com fallback explícito:**

```csharp
private static TimeZoneInfo ObterFuso()
{
    // Tenta IANA primeiro; cai para o identificador do Windows.
    foreach (var id in new[] { "America/Sao_Paulo", "E. South America Standard Time" })
    {
        try
        {
            return TimeZoneInfo.FindSystemTimeZoneById(id);
        }
        catch (TimeZoneNotFoundException) { }
        catch (InvalidTimeZoneException)  { }
    }

    throw new InvalidOperationException(
        "Fuso horario de Sao Paulo nao encontrado no sistema. " +
        "Em container Linux enxuto, instale o pacote tzdata.");
}
```

> **Contêiner sem `tzdata`.** Imagens Alpine e algumas imagens `runtime-deps` não incluem o banco
> de fusos. `FindSystemTimeZoneById` falha para qualquer identificador que não seja `UTC`. A
> mensagem de exceção não sugere a causa — por isso o texto acima diz explicitamente o que
> instalar.

### Horário de verão e dados históricos

O Brasil encerrou o horário de verão em 2019. Isso não significa que a complexidade acabou:
**dados anteriores a 2019 continuam sujeitos à regra antiga**, e `TimeZoneInfo` aplica a regra
correta para a data em questão.

Duas situações que ainda ocorrem em relatório histórico:

```csharp
// Hora que NAO EXISTIU (adiantamento do relogio)
fuso.IsInvalidTime(new DateTime(2018, 11, 4, 0, 30, 0));

// Hora que ocorreu DUAS VEZES (atraso do relogio)
fuso.IsAmbiguousTime(new DateTime(2019, 2, 17, 0, 30, 0));
```

Converter uma hora inválida lança `ArgumentException`. Em importação de arquivo histórico, isso
derruba o lote inteiro se não for tratado.

Sistemas com clientes fora do Brasil enfrentam isso todo ano, não só no histórico.

---

## Regra 4 — Tipos correspondentes no SQL Server

| Tipo .NET | Tipo SQL Server | Observação |
|---|---|---|
| `DateTimeOffset` | `DATETIMEOFFSET` | **Guarda o deslocamento.** Único que preserva a informação completa |
| `DateTime` (UTC) | `DATETIME2(3)` ou `DATETIME2(7)` | Precisão e faixa melhores que `DATETIME` |
| `DateOnly` | `DATE` | 3 bytes, sem hora |
| `TimeOnly` | `TIME(n)` | — |
| `DateTime` | `DATETIME` | **Legado.** Precisão de ~3,33 ms e faixa a partir de 1753 |

### Por que evitar `DATETIME` em coluna nova

```sql
-- DATETIME arredonda para incrementos de 0,000, 0,003 ou 0,007 segundo.
DECLARE @d DATETIME = '2026-08-20 10:00:00.999';
SELECT @d;   -- devolve 2026-08-20 10:00:01.000

-- DATETIME2 preserva o valor
DECLARE @d2 DATETIME2(3) = '2026-08-20 10:00:00.999';
SELECT @d2;  -- devolve 2026-08-20 10:00:00.999
```

Esse arredondamento cria o clássico defeito de intervalo: um registro gravado às `23:59:59.999`
vira `00:00:00.000` do dia seguinte e some do relatório de fechamento.

### Comparar intervalos: sempre meio aberto

```sql
-- ERRADO: BETWEEN perde registros do ultimo dia quando ha hora
WHERE DataPedido BETWEEN '2026-08-01' AND '2026-08-31'

-- ERRADO: '23:59:59.997' e uma gambiarra dependente do tipo
WHERE DataPedido BETWEEN '2026-08-01' AND '2026-08-31 23:59:59.997'

-- CERTO: intervalo meio aberto. Funciona em qualquer tipo e precisao.
WHERE DataPedido >= '2026-08-01'
  AND DataPedido <  '2026-09-01'
```

O intervalo meio aberto (`>=` início, `<` fim) é correto para `DATETIME`, `DATETIME2`,
`DATETIMEOFFSET` e `DATE`, em qualquer precisão. Vale adotá-lo como padrão e parar de pensar no
assunto.

### Não aplique função na coluna

```sql
-- Nao usa indice: a coluna esta dentro de uma funcao (nao e SARGable)
WHERE YEAR(DataPedido) = 2026 AND MONTH(DataPedido) = 8

-- Usa indice
WHERE DataPedido >= '2026-08-01' AND DataPedido < '2026-09-01'
```

Detalhamento em [`sql-server/performance/`](../sql-server/performance/).

### Literal de data em T-SQL: use formato não ambíguo

```sql
-- Interpretacao depende de DATEFORMAT / idioma do login. Evite.
SET @data = '01/02/2026';

-- Sempre inequivoco, independentemente de idioma
SET @data = '20260201';              -- yyyyMMdd
SET @data = '2026-02-01T00:00:00';   -- ISO 8601 com T
```

> `'2026-02-01'` **sem** o `T` pode ser interpretado conforme o idioma da sessão em alguns tipos.
> `yyyyMMdd` e o ISO 8601 completo com `T` são sempre seguros.

---

## Quando NÃO usar UTC

UTC é o padrão correto para **instantes**. Nem tudo é instante:

| Caso | Guarde como | Por quê |
|---|---|---|
| Data de nascimento | `DateOnly` / `DATE` | Não é um instante. Converter para UTC muda a data |
| Vencimento de boleto | `DateOnly` / `DATE` | Vence no dia, não em um instante |
| Competência contábil | `DateOnly` ou ano+mês | Idem |
| Horário de funcionamento | `TimeOnly` / `TIME` | "Abre às 9h" vale em qualquer fuso da loja |
| Compromisso futuro em fuso específico | Instante **e** o identificador do fuso | Se a regra de fuso mudar, o compromisso precisa acompanhar o horário local |

O último caso é sutil e importante: uma reunião marcada para "14h em São Paulo, em março do ano que
vem" não deve ser guardada apenas como UTC. Se a legislação de fuso mudar nesse intervalo, o valor
em UTC passa a apontar para outro horário local. Guarde o horário local **e** o identificador do
fuso, e calcule o instante na hora de usar.

---

## Checklist

- [ ] `DateTimeOffset` para instantes; `DateOnly`/`TimeOnly` para data e hora puras.
- [ ] Nenhum `DateTime.Now` em lógica de negócio — apenas `UtcNow` ou o relógio injetado.
- [ ] Relógio como dependência (`TimeProvider` ou interface própria), para permitir teste.
- [ ] Conversão para fuso local apenas na apresentação.
- [ ] Identificador de fuso com fallback IANA/Windows, e `tzdata` presente no contêiner.
- [ ] Colunas novas em `DATETIME2` ou `DATETIMEOFFSET`, nunca `DATETIME`.
- [ ] Todo filtro de período usa intervalo meio aberto (`>=` e `<`).
- [ ] Nenhuma função aplicada sobre coluna de data no `WHERE`.
- [ ] Literais de data em `yyyyMMdd` ou ISO 8601 com `T`.
- [ ] Datas históricas anteriores a 2019 tratadas com `IsInvalidTime`/`IsAmbiguousTime` quando
      houver conversão de horário local.

---

## Referências

- [Microsoft Learn — Escolher entre DateTime, DateTimeOffset, TimeSpan e TimeZoneInfo](https://learn.microsoft.com/dotnet/standard/datetime/choosing-between-datetime)
- [Microsoft Learn — `TimeZoneInfo.FindSystemTimeZoneById`](https://learn.microsoft.com/dotnet/api/system.timezoneinfo.findsystemtimezonebyid)
- [Microsoft Learn — `TimeProvider`](https://learn.microsoft.com/dotnet/api/system.timeprovider)
- [Microsoft Learn — `date` e `time` no SQL Server](https://learn.microsoft.com/sql/t-sql/data-types/date-and-time-types)
- [Microsoft Learn — `datetime2`](https://learn.microsoft.com/sql/t-sql/data-types/datetime2-transact-sql)

---

**Criado por Fábio Cerqueira**
