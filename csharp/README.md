# C# — fundamentos que produzem defeito em produção

> Esta área não ensina a linguagem. Ela cobre os pontos em que o C# se comporta de um jeito na
> máquina de quem desenvolve e de outro no servidor.

---

## Conteúdo

| Documento | Resolve |
|---|---|
| [Datas e fuso horário](datas-e-fuso-horario.md) | Relatório com um dia a mais, `DateTime.Now` acoplado ao servidor, `DATETIME` que arredonda e some com o registro das 23:59:59.999, `BETWEEN` que perde o último dia, `tzdata` ausente no contêiner |
| [Cultura, encoding e comparação de strings](cultura-encoding-e-comparacao-de-strings.md) | Valor que virou mil vezes maior, `José` que virou `Jos�`, busca que não acha o registro, collation conflitante, `CONVERT_IMPLICIT` que mata o índice |

Outros temas de C# e .NET estão em [`dotnet/`](../dotnet/):

- [`dotnet/async-await/`](../dotnet/async-await/) — deadlock por `sync-over-async`, `ConfigureAwait`
- [`dotnet/excecoes/`](../dotnet/excecoes/) — o que nunca engolir, exceções transitórias
- [`dotnet/json/`](../dotnet/json/) — `System.Text.Json` e `Newtonsoft.Json`
- [`dotnet/httpclient/`](../dotnet/httpclient/) — esgotamento de socket, DNS obsoleto, timeout
- [`dotnet/logging/`](../dotnet/logging/) — log estruturado, correlation ID
- [`dotnet/dependency-injection/`](../dotnet/dependency-injection/) — tempos de vida, dependência cativa
- [`dotnet/background-services/`](../dotnet/background-services/) — job que derruba a aplicação
- [`dotnet/diagnostico/`](../dotnet/diagnostico/) — aplicação lenta, travando ou consumindo memória

---

## O padrão por trás de quase todo defeito desta área

**A aplicação depende de algo ambiente que ela não declarou.**

| O que está implícito | O que muda no servidor | Como tornar explícito |
|---|---|---|
| Cultura corrente | Idioma do SO, contêiner com `LANG=C`, `InvariantGlobalization` | `CultureInfo.InvariantCulture` em toda integração |
| Fuso horário local | Servidor em UTC, contêiner sem `tzdata` | `DateTimeOffset` e conversão só na apresentação |
| Encoding do arquivo | Parceiro trocou o gerador | Encoding declarado no contrato e no código |
| Regra de comparação de texto | Cultura da thread | `StringComparison.Ordinal` para identificador |
| Relógio do sistema | Nada — mas impede testar | `TimeProvider` ou interface própria |
| Tipo do parâmetro SQL | Nada — mas o plano muda | `SqlDbType` e tamanho declarados |

Esse é o teste útil ao revisar código: **este trecho se comporta igual em um contêiner Linux em
UTC com cultura invariante?** Se a resposta for "não sei", há algo implícito para declarar.

---

## Legado e moderno

Boa parte do conteúdo aqui vale para as duas plataformas, com API diferente. Quando houver
diferença relevante, os documentos apresentam **Legado → Intermediário → Moderno** — e o estágio
intermediário importa, porque ele melhora o sistema **sem** exigir um projeto de migração.

Exemplos deste repositório:

- `CodePagesEncodingProvider` é necessário no .NET Core/5+ e desnecessário no .NET Framework.
- `TimeProvider` existe no .NET 8+; em versões anteriores, uma interface `IRelogio` cumpre o papel.
- `DateOnly`/`TimeOnly` exigem .NET 6+; antes disso, o cuidado com a hora zerada continua sendo
  manual.

Ver também [`aspnet/mapa-de-versoes-e-equivalencias.md`](../aspnet/mapa-de-versoes-e-equivalencias.md).

---

**Criado por Fábio Cerqueira**
