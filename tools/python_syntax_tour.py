#!/usr/bin/env python3
"""
Большой учебный скрипт по синтаксису Python для разработчика с опытом C#.

Как запускать:
    python3 tools/python_syntax_tour.py
    python3 tools/python_syntax_tour.py --section basics
    python3 tools/python_syntax_tour.py --list

Скрипт намеренно насыщен конструкциями языка. Комментарии объясняют синтаксис,
сравнивают его с C#/.NET и иногда с JavaScript. Примеры маленькие и безопасные:
они работают только с памятью, временными файлами и стандартной библиотекой.

Источники для фактов о модели объектов и runtime:
- https://docs.python.org/3/reference/datamodel.html
- https://docs.python.org/3/glossary.html#term-global-interpreter-lock
- https://docs.python.org/3/reference/compound_stmts.html
"""

from __future__ import annotations

# Импорты в Python выполняют код модуля один раз и кладут модуль в кеш sys.modules.
# В C# using обычно подключает namespace/alias на этапе компиляции, а сборки грузит CLR.
import argparse
import asyncio
import contextlib
import dataclasses
import decimal
import enum
import functools
import gc
import inspect
import itertools
import json
import math
import operator
import pathlib
import random
import re
import statistics
import sys
import tempfile
import threading
import time
import types
import typing
import warnings
from collections import Counter, defaultdict, deque, namedtuple
from collections.abc import Generator, Iterable, Iterator
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from enum import Enum, Flag, auto
from functools import cached_property, partial, singledispatch, wraps
from typing import Any, ClassVar, Final, Literal, NamedTuple, Protocol, Self, TypeAlias


SECTION_OUTPUT_LIMIT = 12


def show(title: str, value: Any = "") -> None:
    """Единый вывод примеров: скрипт остается читаемым и легко фильтруется глазами."""
    if value == "":
        print(f"\n--- {title} ---")
    else:
        print(f"{title}: {value!r}")


def section(name: str):
    """Декоратор регистрирует учебные разделы; в C# похожую роль мог бы играть атрибут."""

    def decorator(func):
        REGISTRY[name] = func
        return func

    return decorator


REGISTRY: dict[str, typing.Callable[[], Any]] = {}


@section("runtime")
def runtime_model() -> None:
    show("runtime")

    # Python обычно запускается интерпретатором CPython: исходник компилируется в bytecode,
    # затем исполняется виртуальной машиной. В .NET C# компилируется в IL, который CLR обычно
    # JIT-компилирует в машинный код. Но у обеих платформ есть варианты: NativeAOT у .NET,
    # PyPy/Jython/IronPython/экспериментальные free-threaded сборки у Python.
    show("implementation", sys.implementation.name)
    show("python version", sys.version.split()[0])
    show("bytecode cache tag", sys.implementation.cache_tag)

    # Все данные в Python представлены объектами с identity/type/value.
    # В C# есть разделение value types/reference types; в Python пользователь почти всегда
    # работает со ссылками на объекты, даже когда пишет x = 10.
    x = 10
    y = 10
    show("identity/type/value", (id(x) == id(y), type(x).__name__, x))

    # CPython использует reference counting плюс циклический GC. .NET GC трассирующий,
    # поколенческий, и не освобождает объект строго в момент выхода из области видимости.
    # В Python тоже нельзя зависеть от финализации: файл закрывают через with, как using в C#.
    show("gc enabled", gc.isenabled())

    # GIL: классический CPython допускает только один поток, исполняющий Python bytecode
    # одновременно. Это не равно "нет многопоточности": I/O и C-расширения могут отпускать GIL.
    # Для CPU-bound параллелизма чаще берут multiprocessing или native code.
    show("threading runtime note", "GIL affects CPU-bound Python threads in CPython")

    # pip/venv ближе к NuGet + per-project environment, но Python-пакеты импортируются
    # динамически во время выполнения; нет единой CLR-сборки с compile-time проверкой типов.
    show("module search path first item", sys.path[0])


@section("basics")
def basics() -> None:
    show("basics")

    # Отступы являются синтаксисом блока. В C# блок задается фигурными скобками.
    if True:
        message = "indentation creates a block"
    show("indentation", message)

    # Комментарий начинается с #. Многострочного комментария как /* ... */ нет:
    # тройные строки часто используют как docstring, но это все равно строковый литерал.
    def documented_function() -> str:
        """Docstring доступен через __doc__; XML-doc comments C# компилируются иначе."""
        return "docstrings are runtime data"

    show("docstring", documented_function.__doc__.split(";")[0])

    # Имена привязываются к объектам. Тип имени не фиксируется; тип есть у объекта.
    # В C# var статически выводит тип один раз, а dynamic откладывает проверку на runtime.
    value = 42
    value = "now a string"
    show("dynamic binding", value)

    # Аннотации типов не исполняют проверку. Их читают IDE, mypy/pyright и документация.
    age: int = "тридцать"  # type: ignore[assignment]
    show("type hints are not runtime checks", age)

    # None похож на null, но это singleton-объект. Проверяют через is, а не ==.
    nothing = None
    show("None identity", nothing is None)

    # bool является подклассом int: историческая особенность Python.
    # В C# bool не приводится к int автоматически.
    show("bool is int subclass", (isinstance(True, int), True + True))

    # Распаковка заменяет часть tuple deconstruction из C#.
    first, *middle, last = [1, 2, 3, 4, 5]
    show("unpacking with star", (first, middle, last))

    # Морж := присваивает внутри выражения. В C# похожая идея встречается с out var,
    # но Python ограничивает места применения ради читаемости.
    if (length := len(middle)) > 2:
        show("walrus operator", length)

    # Ellipsis ... часто служит заглушкой или частью slicing в NumPy.
    todo = ...
    show("ellipsis object", todo is Ellipsis)

    # del удаляет привязку имени или элемент контейнера. Это не Dispose и не delete из C++.
    temporary_name = "bound"
    del temporary_name
    show("del removes a name", "temporary_name" not in locals())


@section("numbers_strings")
def numbers_and_strings() -> None:
    show("numbers and strings")

    # int в Python произвольной точности; C# int фиксирован 32 битами, BigInteger отдельный тип.
    big = 2**200
    show("arbitrary precision int digits", len(str(big)))

    # / всегда возвращает float. // делает floor division: для отрицательных чисел это важно.
    # В C# деление int/int усекает к нулю.
    show("division", {"7 / 3": 7 / 3, "7 // 3": 7 // 3, "-7 // 3": -7 // 3})

    # Остаток % согласован с floor division: знак результата как у делителя.
    # В C# remainder сохраняет знак делимого.
    show("modulo sign", {"python -7 % 3": -7 % 3})

    # float - double precision. Decimal нужен для денег, как decimal в C#.
    show("float surprise", 0.1 + 0.2)
    show("Decimal exact", Decimal("0.1") + Decimal("0.2"))

    # complex встроен в язык; в C# есть System.Numerics.Complex.
    z = 3 + 4j
    show("complex", (z.real, z.imag, abs(z)))

    # Строки Unicode. Нет отдельного char: "x"[0] возвращает строку длиной 1.
    text = "Zażółć gęślą jaźń"
    show("unicode string", (text[0], type(text[0]).__name__, len(text)))

    # f-string похож на interpolation $"..." в C#, но выражения Python выполняются прямо внутри.
    name = "Python"
    show("f-string", f"{name=}, pi≈{math.pi:.3f}")

    # raw string удобен для regex/path; в C# есть verbatim string @"...".
    pattern = r"\b\w{3}\b"
    show("raw string regex", re.findall(pattern, "one two three"))

    # bytes - неизменяемая последовательность байтов; str.encode/decode задают кодировку.
    encoded = text.encode("utf-8")
    show("bytes roundtrip", encoded.decode("utf-8") == text)

    # Срезы [start:stop:step] встроены в синтаксис. stop не включается.
    show("slicing", text[:7],)
    show("reverse slice", text[::-1])

    # Строки неизменяемы, поэтому replace возвращает новую строку.
    show("immutability", text.replace("ż", "z"))

///////////////////////////////
stop
/////
@section("collections")
def collections_demo() -> None:
    show("collections")

    # list - изменяемый динамический массив, близок к List<T>, но элементы разных типов допустимы.
    items = [1, "two", 3.0]
    items.append({"four": 4})
    show("list", items)

    # tuple - неизменяемый контейнер. Одноэлементный tuple требует запятую.
    one_item_tuple = ("only",)
    show("tuple comma", one_item_tuple)

    # В tuple могут лежать ссылки на изменяемые объекты: сам tuple не меняет состав ссылок,
    # но вложенный list меняется.
    tricky = ([1, 2], "stable")
    tricky[0].append(3)
    show("immutable container with mutable child", tricky)

    # dict сохраняет порядок вставки в современных Python. В C# Dictionary тоже сохраняет
    # порядок в актуальных реализациях .NET, но исторически контракт часто воспринимали иначе.
    capitals = {"PL": "Warsaw", "US": "Washington", "JP": "Tokyo"}
    capitals["FR"] = "Paris"
    show("dict", list(capitals.items()))

    # set хранит уникальные hashable элементы. list нельзя положить в set, tuple можно,
    # если все элементы tuple hashable.
    show("set operations", {1, 2, 3} & {2, 3, 4})

    # dict/list/set comprehensions - компактный аналог LINQ Select/Where.
    squares = {n: n * n for n in range(6) if n % 2 == 0}
    show("dict comprehension", squares)

    # generator expression ленивый, ближе к LINQ deferred execution.
    gen = (n * n for n in range(3))
    show("generator expression", list(gen))

    # defaultdict убирает проверку ContainsKey перед добавлением.
    groups: defaultdict[str, list[str]] = defaultdict(list)
    for word in ["kot", "pies", "kawa", "python"]:
        groups[word[0]].append(word)
    show("defaultdict", dict(groups))

    # Counter - готовый счетчик частот.
    show("Counter", Counter("abracadabra").most_common(3))

    # deque подходит для очередей с быстрым append/pop с обоих концов.
    queue = deque(["first", "second"])
    queue.appendleft("zero")
    show("deque", list(queue))

    # namedtuple старше dataclass: tuple с именованными полями.
    Point2D = namedtuple("Point2D", "x y")
    show("namedtuple", Point2D(10, 20).x)

    # copy: присваивание копирует ссылку, не объект. Это как две переменные-ссылки в C#.
    a = [[1], [2]]
    b = a
    shallow = a.copy()
    a[0].append(99)
    show("assignment vs shallow copy", {"same": b, "shallow": shallow})


@section("control_flow")
def control_flow() -> None:
    show("control flow")

    # if/elif/else вместо if/else if/else.
    score = 87
    if score >= 90:
        grade = "A"
    elif score >= 75:
        grade = "B"
    else:
        grade = "C"
    show("if elif else", grade)

    # Тернарное выражение читается как "A if condition else B"; в C# condition ? A : B.
    show("conditional expression", "pass" if score >= 60 else "fail")

    # Truthiness: пустые коллекции, 0, "", None - false. В C# bool-условие должно быть bool.
    values = [[], [1], "", "x", 0, 42, None]
    show("truthiness", [bool(v) for v in values])

    # for итерирует по iterable, а не по индексу. range ленивый.
    seen = []
    for index, letter in enumerate("abc", start=1):
        seen.append((index, letter))
    show("for enumerate", seen)

    # zip(strict=True) ловит разные длины, похож на защиту от тихой потери данных.
    show("zip strict", list(zip([1, 2], ["a", "b"], strict=True)))

    # for/else выполняет else, если цикл не завершился break. В C# такого блока нет.
    for number in [2, 4, 6]:
        if number % 2:
            found_odd = True
            break
    else:
        found_odd = False
    show("for else", found_odd)

    # while тоже поддерживает else.
    countdown = 3
    while countdown:
        countdown -= 1
    else:
        show("while else", "loop exhausted")

    # continue переходит к следующей итерации, break выходит из цикла.
    filtered = []
    for n in range(10):
        if n % 2:
            continue
        if n > 5:
            break
        filtered.append(n)
    show("continue break", filtered)

    # match/case - structural pattern matching. Это не switch по одному значению, а сопоставление
    # формы объекта. В C# pattern matching похож идеей, но синтаксис и правила другие.
    command: object = {"action": "move", "x": 10, "y": 20}
    match command:
        case {"action": "move", "x": int(x), "y": int(y)} if x >= 0 and y >= 0:
            result = f"move to {x},{y}"
        case {"action": "quit"}:
            result = "quit"
        case _:
            result = "unknown"
    show("match mapping pattern", result)

    # Sequence pattern распаковывает форму списка/tuple.
    point = (0, 5)
    match point:
        case (0, y):
            show("match sequence pattern", f"on y-axis at {y}")
        case (x, 0):
            show("match sequence pattern", f"on x-axis at {x}")
        case (x, y):
            show("match sequence pattern", f"free point {x},{y}")


@section("functions")
def functions_demo() -> None:
    show("functions")

    # Параметры могут быть positional-only до / и keyword-only после *.
    # В C# вызов по имени есть, но синтаксис объявления другой.
    def connect(host: str, /, port: int = 443, *, timeout: float = 1.0) -> str:
        return f"{host}:{port} timeout={timeout}"

    show("positional-only and keyword-only", connect("example.com", timeout=0.5))

    # *args собирает позиционные аргументы, **kwargs - именованные.
    def collect(*args: int, **kwargs: str) -> tuple[tuple[int, ...], dict[str, str]]:
        return args, kwargs

    show("args kwargs", collect(1, 2, mode="fast"))

    # Осторожно: default arguments создаются один раз при определении функции.
    # В C# default values компилируются в call site и не являются изменяемым объектом функции.
    def bad_append(item: str, bucket: list[str] = []) -> list[str]:  # noqa: B006 - учебный пример
        bucket.append(item)
        return bucket

    show("mutable default pitfall", (bad_append("a"), bad_append("b")))

    def good_append(item: str, bucket: list[str] | None = None) -> list[str]:
        bucket = [] if bucket is None else bucket
        bucket.append(item)
        return bucket

    show("None default pattern", (good_append("a"), good_append("b")))

    # lambda - маленькая функция-выражение; полноценное тело с несколькими statements нельзя.
    show("lambda", sorted(["aaa", "b", "cc"], key=lambda s: len(s)))

    # Замыкание хранит ссылки на переменные внешней области.
    def make_counter(start: int = 0):
        current = start

        def next_value() -> int:
            nonlocal current  # nonlocal меняет привязку во внешней функции.
            current += 1
            return current

        return next_value

    counter = make_counter(10)
    show("closure nonlocal", (counter(), counter()))

    # global меняет имя на уровне модуля; обычно лучше избегать ради тестируемости.
    global GLOBAL_SWITCH
    GLOBAL_SWITCH = "set by global statement"
    show("global", GLOBAL_SWITCH)

    # Декоратор принимает функцию и возвращает функцию. Это близко к middleware/wrapper,
    # а не к C# attributes, потому что реально заменяет объект функции.
    def trace(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            return f"{func.__name__} -> {func(*args, **kwargs)}"

        return wrapper

    @trace
    def add(a: int, b: int) -> int:
        return a + b

    show("decorator", add(2, 3))

    # singledispatch - runtime overload по типу первого аргумента.
    # В C# overload resolution статическая и богаче.
    @singledispatch
    def describe(value: object) -> str:
        return f"object:{value!r}"

    @describe.register
    def _(value: int) -> str:
        return f"int:{value}"

    show("singledispatch", (describe(5), describe("x")))

    # partial фиксирует часть аргументов, похож на каррирование/лямбду.
    power_of_two = partial(pow, 2)
    show("partial", power_of_two(8))

    # Функции - объекты первого класса: их можно хранить, передавать, инспектировать.
    show("function object", inspect.signature(connect))


GLOBAL_SWITCH = "initial"


@section("iterators")
def iterators_demo() -> None:
    show("iterators and generators")

    # iterable возвращает iterator через iter(); iterator возвращает следующий элемент через next().
    iterator = iter(["a", "b"])
    show("iterator protocol", (next(iterator), next(iterator)))

    # Классический итератор: __iter__ возвращает self, __next__ поднимает StopIteration.
    class Countdown:
        def __init__(self, start: int) -> None:
            self.current = start

        def __iter__(self) -> Self:
            return self

        def __next__(self) -> int:
            if self.current <= 0:
                raise StopIteration
            self.current -= 1
            return self.current + 1

    show("custom iterator", list(Countdown(3)))

    # yield превращает функцию в генератор. Код выполняется лениво до следующего yield.
    def fibonacci(limit: int) -> Generator[int, None, None]:
        a, b = 0, 1
        while a < limit:
            yield a
            a, b = b, a + b

    show("yield generator", list(fibonacci(20)))

    # yield from делегирует другому iterable.
    def chain_examples() -> Iterator[int]:
        yield from [1, 2]
        yield from range(3, 5)

    show("yield from", list(chain_examples()))

    # Генератор может принимать значения через send, но это реже нужно в обычном коде.
    def accumulator() -> Generator[int, int, None]:
        total = 0
        while True:
            incoming = yield total
            total += incoming

    acc = accumulator()
    first_total = next(acc)
    second_total = acc.send(5)
    third_total = acc.send(7)
    acc.close()
    show("generator send close", (first_total, second_total, third_total))

    # itertools дает building blocks для ленивых последовательностей.
    show("itertools", list(itertools.islice(itertools.count(10, 2), 4)))


@section("classes")
def classes_demo() -> None:
    show("classes")

    # class создает объект-класс во время выполнения. В C# class - compile-time type declaration.
    class Animal:
        kingdom: ClassVar[str] = "animalia"  # ClassVar говорит type checker, что поле классовое.

        def __init__(self, name: str) -> None:
            self.name = name  # self явный; в C# this не пишется в списке параметров.

        def speak(self) -> str:
            return f"{self.name} makes a sound"

        def __repr__(self) -> str:
            return f"Animal(name={self.name!r})"

    cat = Animal("Kot")
    show("class instance", (cat.speak(), repr(cat), Animal.kingdom))

    # Наследование и super(). Python поддерживает multiple inheritance и MRO.
    class LoudAnimal(Animal):
        def speak(self) -> str:
            return super().speak().upper()

    show("inheritance super", LoudAnimal("Dog").speak())
    show("MRO", [cls.__name__ for cls in LoudAnimal.__mro__])

    # @property выглядит как поле, но вызывает метод. В C# аналог - property get/set.
    class Temperature:
        def __init__(self, celsius: float) -> None:
            self.celsius = celsius

        @property
        def fahrenheit(self) -> float:
            return self.celsius * 9 / 5 + 32

        @fahrenheit.setter
        def fahrenheit(self, value: float) -> None:
            self.celsius = (value - 32) * 5 / 9

    temp = Temperature(0)
    temp.fahrenheit = 212
    show("property", temp.celsius)

    # staticmethod не получает self/class; classmethod получает class и часто служит factory.
    class User:
        def __init__(self, email: str) -> None:
            self.email = email

        @staticmethod
        def normalize(email: str) -> str:
            return email.strip().lower()

        @classmethod
        def from_raw(cls, email: str) -> Self:
            return cls(cls.normalize(email))

    show("staticmethod classmethod", User.from_raw(" A@EXAMPLE.COM ").email)

    # dataclass генерирует __init__, __repr__, __eq__. Похоже на record в C#,
    # но mutability зависит от frozen=True.
    @dataclass(order=True, frozen=True, slots=True)
    class Course:
        sort_index: int = field(init=False, repr=False)
        title: str
        lessons: int = 0

        def __post_init__(self) -> None:
            object.__setattr__(self, "sort_index", self.lessons)

    show("dataclass frozen slots", sorted([Course("B", 2), Course("A", 1)]))

    # Protocol - structural typing для type checkers: важно наличие методов, а не наследование.
    class HasArea(Protocol):
        def area(self) -> float: ...

    class Square:
        def __init__(self, side: float) -> None:
            self.side = side

        def area(self) -> float:
            return self.side * self.side

    def total_area(shapes: Iterable[HasArea]) -> float:
        return sum(shape.area() for shape in shapes)

    show("Protocol structural typing", total_area([Square(3)]))

    # Descriptor управляет доступом к атрибуту через __get__/__set__; property построен на идее
    # descriptor protocol.
    class Positive:
        def __set_name__(self, owner, name):
            self.private_name = f"_{name}"

        def __get__(self, obj, owner=None):
            return self if obj is None else getattr(obj, self.private_name)

        def __set__(self, obj, value):
            if value <= 0:
                raise ValueError("must be positive")
            setattr(obj, self.private_name, value)

    class Box:
        width = Positive()

        def __init__(self, width: int) -> None:
            self.width = width

    show("descriptor", Box(5).width)


@section("enums_typing")
def enums_and_typing() -> None:
    show("enums and typing")

    class Color(Enum):
        RED = "red"
        GREEN = "green"
        BLUE = "blue"

    show("Enum", (Color.RED, Color.RED.value, Color("red")))

    class Permission(Flag):
        READ = auto()
        WRITE = auto()
        EXECUTE = auto()

    show("Flag enum", Permission.READ | Permission.WRITE)

    # TypeAlias, Literal и Final помогают type checker, но не замораживают runtime.
    UserId: TypeAlias = int
    DEFAULT_ROLE: Final[Literal["reader"]] = "reader"
    user_id: UserId = 100
    show("typing aliases", (user_id, DEFAULT_ROLE))

    # Union пишется через | с Python 3.10.
    maybe_number: int | None = 5
    show("union syntax", maybe_number)

    # New style generic classes используют [] в наследовании от typing/collections.abc.
    T = typing.TypeVar("T")

    class Stack(typing.Generic[T]):
        def __init__(self) -> None:
            self._items: list[T] = []

        def push(self, item: T) -> None:
            self._items.append(item)

        def pop(self) -> T:
            return self._items.pop()

    stack = Stack[int]()
    stack.push(10)
    show("Generic class", stack.pop())

    # NamedTuple - typed tuple с именами полей.
    class Location(NamedTuple):
        lat: float
        lon: float

    show("NamedTuple", Location(52.23, 21.01))


@section("exceptions")
def exceptions_demo() -> None:
    show("exceptions")

    # try/except/else/finally: else выполняется, если исключения не было.
    try:
        parsed = int("42")
    except ValueError as exc:
        show("except", exc)
    else:
        show("else after try", parsed)
    finally:
        show("finally", "always runs")

    # raise from сохраняет цепочку причин. В C# есть inner exception.
    try:
        try:
            int("not a number")
        except ValueError as exc:
            raise RuntimeError("parsing failed") from exc
    except RuntimeError as exc:
        show("exception chaining", type(exc.__cause__).__name__)

    # except* обрабатывает ExceptionGroup по частям. Это появилось для async/concurrent задач.
    try:
        raise ExceptionGroup(
            "many failures",
            [ValueError("bad value"), TypeError("bad type"), ValueError("another bad value")],
        )
    except* ValueError as group:
        show("except* ValueError count", len(group.exceptions))
    except* TypeError as group:
        show("except* TypeError count", len(group.exceptions))

    # warnings - не exception по умолчанию, а канал предупреждений.
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        warnings.warn("deprecated soon", DeprecationWarning, stacklevel=1)
        show("warnings", caught[0].category.__name__)


@section("context_managers")
def context_managers_demo() -> None:
    show("context managers")

    # with вызывает __enter__/__exit__. Это ближайший аналог using в C# для ресурсов.
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / "data.json"
        path.write_text(json.dumps({"language": "Python"}, ensure_ascii=False), encoding="utf-8")
        data = json.loads(path.read_text(encoding="utf-8"))
        show("with temp file json", data)

    # contextlib.contextmanager строит context manager из генератора.
    @contextlib.contextmanager
    def timer(label: str) -> Iterator[None]:
        started = time.perf_counter()
        try:
            yield
        finally:
            elapsed_ms = (time.perf_counter() - started) * 1000
            show(f"timer {label}", round(elapsed_ms, 3))

    with timer("tiny block"):
        sum(range(1000))

    # suppress намеренно гасит исключение; использовать аккуратно, чтобы не прятать баги.
    with contextlib.suppress(FileNotFoundError):
        pathlib.Path("file-that-does-not-exist.txt").read_text()
    show("contextlib.suppress", "missing file ignored")

    # ExitStack удобен, когда количество ресурсов динамическое.
    with contextlib.ExitStack() as stack:
        temp_dir = stack.enter_context(tempfile.TemporaryDirectory())
        file = stack.enter_context(open(pathlib.Path(temp_dir) / "note.txt", "w", encoding="utf-8"))
        file.write("hello")
    show("ExitStack", "resources closed")


@section("stdlib")
def stdlib_demo() -> None:
    show("standard library")

    # pathlib.Path вместо ручной склейки строк путей; похож на System.IO.Path/FileInfo.
    path = pathlib.Path("tools") / "python_syntax_tour.py"
    show("pathlib suffix", path.suffix)

    # datetime: используйте timezone-aware время, UTC удобно импортируется как datetime.UTC.
    now = datetime.now(UTC)
    show("datetime aware", now.tzinfo)
    show("timedelta", (now + timedelta(days=7)).date())

    # re - регулярные выражения. Синтаксис близок к .NET Regex, но не идентичен.
    show("regex named group", re.match(r"(?P<word>\w+)", "python").group("word"))

    # statistics/math/operator - маленькие полезные модули.
    show("statistics", statistics.mean([10, 20, 30]))
    show("operator", operator.itemgetter("name")({"name": "Ada"}))

    # random не для криптографии; secrets нужен для токенов.
    random.seed(123)
    show("random deterministic", [random.randint(1, 6) for _ in range(3)])

    # decimal context похож на настройку точности вычислений.
    with decimal.localcontext() as ctx:
        ctx.prec = 4
        show("decimal context", Decimal("1") / Decimal("7"))


@section("async_threads")
def async_and_threads() -> None:
    show("async and threads")

    # async/await в Python похож на C#, но работает поверх event loop.
    # await переключает задачу только в точках ожидания; CPU-bound код сам себя не распараллелит.
    async def fetch_fake(name: str, delay: float) -> str:
        await asyncio.sleep(delay)
        return f"{name} done"

    async def async_main() -> list[str]:
        # TaskGroup структурирует конкурентные async-задачи. При ошибке отменяет соседей.
        async with asyncio.TaskGroup() as group:
            task_a = group.create_task(fetch_fake("A", 0.01))
            task_b = group.create_task(fetch_fake("B", 0.01))
        return [task_a.result(), task_b.result()]

    show("asyncio TaskGroup", asyncio.run(async_main()))

    # async generator использует async for.
    async def async_numbers() -> typing.AsyncIterator[int]:
        for n in range(3):
            await asyncio.sleep(0)
            yield n

    async def collect_async_numbers() -> list[int]:
        result = []
        async for n in async_numbers():
            result.append(n)
        return result

    show("async for", asyncio.run(collect_async_numbers()))

    # threading полезен для I/O-bound работы. Для CPU-bound в CPython GIL ограничивает
    # параллельное исполнение Python bytecode.
    lock = threading.Lock()
    shared: list[int] = []

    def worker(value: int) -> None:
        with lock:
            shared.append(value)

    threads = [threading.Thread(target=worker, args=(n,)) for n in range(3)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    show("threading lock", sorted(shared))

    # ThreadPoolExecutor часто удобнее ручного создания Thread.
    with ThreadPoolExecutor(max_workers=2) as pool:
        show("ThreadPoolExecutor", list(pool.map(lambda n: n * n, range(4))))


@section("dunder")
def dunder_methods_demo() -> None:
    show("dunder methods")

    # Dunder методы (__len__, __add__...) подключают объект к синтаксису языка.
    # В C# этому соответствуют interfaces и operator overloads, но правила отличаются.
    @dataclass(frozen=True)
    class Vector:
        x: float
        y: float

        def __add__(self, other: Self) -> Self:
            return type(self)(self.x + other.x, self.y + other.y)

        def __mul__(self, scalar: float) -> Self:
            return type(self)(self.x * scalar, self.y * scalar)

        def __len__(self) -> int:
            # __len__ обязан вернуть int; bool(obj) использует __len__, если нет __bool__.
            return round(math.hypot(self.x, self.y))

        def __bool__(self) -> bool:
            return self.x != 0 or self.y != 0

        def __iter__(self) -> Iterator[float]:
            yield self.x
            yield self.y

    vector = Vector(3, 4)
    show("operator overload", vector + Vector(1, 1))
    show("truthiness dunder", (len(vector), bool(Vector(0, 0))))
    show("iter dunder unpack", tuple(vector))

    # __getattr__ вызывается только для отсутствующих атрибутов.
    class DynamicConfig:
        def __getattr__(self, name: str) -> str:
            if name.startswith("feature_"):
                return "disabled"
            raise AttributeError(name)

    show("__getattr__", DynamicConfig().feature_chat)


@section("modules_cli")
def modules_and_cli() -> None:
    show("modules and cli")

    # __name__ == "__main__" означает запуск файла как скрипта. При import имя будет другим.
    show("__name__", __name__)

    # argparse - стандартный способ CLI. Здесь основной parser в main(), а не в глобальном коде,
    # чтобы import модуля не запускал парсинг аргументов.
    show("argparse note", "see main()")

    # Модули могут быть созданы динамически, хотя в обычном коде так почти не делают.
    module = types.ModuleType("demo_module")
    module.answer = 42
    show("dynamic module", module.answer)

    # __all__ в модуле задает, что экспортировать при from module import *.
    show("__all__", __all__)


__all__ = ["REGISTRY", "main"]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Учебный tour по синтаксису Python с комментариями для C#/.NET разработчика."
    )
    parser.add_argument("--list", action="store_true", help="Показать доступные разделы.")
    parser.add_argument(
        "--section",
        choices=sorted(REGISTRY),
        help="Запустить один раздел вместо всего скрипта.",
    )
    args = parser.parse_args(argv)

    if args.list:
        for name in sorted(REGISTRY):
            print(name)
        return 0

    if args.section:
        REGISTRY[args.section]()
        return 0

    for name, func in REGISTRY.items():
        func()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
