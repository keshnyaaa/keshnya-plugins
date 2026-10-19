#!/bin/sh
# Сценарный тест safe-mutation.sh. Работает только во временных каталогах,
# запускается из любого каталога:
#
#   sh safe-mutation.test.sh
#   SM_SHELL=/bin/dash /bin/dash safe-mutation.test.sh
#
# SM_SHELL — оболочка, в которой тест запускает помощник (по умолчанию sh).
# Выход: 0 — все проверки прошли, 1 — хотя бы одна упала.

set -u

here=$(cd "$(dirname "$0")" && pwd -P) || exit 1
helper=$here/safe-mutation.sh
SM_SHELL=${SM_SHELL:-sh}

t=$(mktemp -d "${TMPDIR:-/tmp}/safe-mutation-test.XXXXXX") || exit 1
t=$(cd "$t" && pwd -P)
trap 'rm -rf "$t"' EXIT INT TERM
results=$t/failures
: >"$results"
scenario_no=0

ok() {
	printf '  ok   %s\n' "$1"
}

bad() {
	printf '  FAIL %s\n' "$1"
	printf '%s\n' "$1" >>"$results"
}

# check ОПИСАНИЕ КОМАНДА...: проходит, если команда вернула 0.
check() {
	desc=$1
	shift
	if "$@"; then ok "$desc"; else bad "$desc"; fi
}

# sm АРГУМЕНТЫ...: запускает помощника; вывод в $out, код в $rc.
sm() {
	out=$("$SM_SHELL" "$helper" "$@" 2>&1)
	rc=$?
}

rc_zero() { [ "$rc" -eq 0 ]; }
rc_nonzero() { [ "$rc" -ne 0 ]; }
out_has() { printf '%s\n' "$out" | grep -qF -- "$1"; }
same() { cmp -s "$1" "$2"; }
gone() { [ ! -e "$1" ] && [ ! -L "$1" ]; }

# Каждый сценарий — свой подкаталог с проектом и собственным TMPDIR.
new_scenario() {
	scenario_no=$((scenario_no + 1))
	sdir=$t/s$scenario_no
	mkdir -p "$sdir/proj" "$sdir/tmp" "$sdir/ref"
	TMPDIR=$sdir/tmp
	export TMPDIR
	proj=$sdir/proj
	cd "$proj" || exit 1
}

# Эталоны пишутся литералами независимо от помощника.
make_fixtures() {
	printf 'first\nsecond\n' >a.txt
	mkdir -p 'dir with space'
	printf 'spaced\n' >'dir with space/b.txt'
	printf '\000\001\377\n\000\200' >bin.dat
	printf 'no newline at end' >nonl.txt
	cp a.txt "$sdir/ref/a.txt"
	cp 'dir with space/b.txt' "$sdir/ref/b.txt"
	cp bin.dat "$sdir/ref/bin.dat"
	cp nonl.txt "$sdir/ref/nonl.txt"
}

scenario_b1() {
	echo 'Б1: повторное сохранение отказывает и копии не трогает'
	new_scenario
	make_fixtures
	sm save a.txt
	check 'первое сохранение проходит' rc_zero
	printf 'CORRUPTED\n' >a.txt
	sm save a.txt
	check 'повторное сохранение того же файла: ненулевой код' rc_nonzero
	check 'сообщение называет причину и restore' out_has 'restore'
	sm save bin.dat
	check 'повторное сохранение другого файла: ненулевой код' rc_nonzero
	sm restore
	check 'возврат проходит' rc_zero
	check 'возврат даёт исходное содержимое, а не испорченное' same a.txt "$sdir/ref/a.txt"
	sm save bin.dat
	check 'после возврата новое сохранение разрешено' rc_zero
	sm restore
}

scenario_b2() {
	echo 'Б2: возврат байт в байт, удаление созданного, снятие состояния'
	new_scenario
	make_fixtures
	sm save a.txt 'dir with space/b.txt' bin.dat nonl.txt \
		new/deep/er/created.txt 'dir with space/fresh.txt'
	check 'сохранение пяти и более записей проходит' rc_zero
	check 'отсутствующий файл назван в выводе' out_has 'new/deep/er/created.txt'

	printf 'X' >a.txt
	printf 'Y' >'dir with space/b.txt'
	printf 'Z' >bin.dat
	printf 'W\n' >nonl.txt
	mkdir -p new/deep/er
	printf 'junk' >new/deep/er/created.txt
	printf 'junk' >'dir with space/fresh.txt'
	printf 'untouched' >unrelated.txt

	sm status
	check 'status показывает изменённый файл' out_has 'сейчас отличается'

	sm restore
	check 'возврат: нулевой код' rc_zero
	check 'a.txt совпадает с эталоном' same a.txt "$sdir/ref/a.txt"
	check 'файл с пробелом в пути совпадает' same 'dir with space/b.txt' "$sdir/ref/b.txt"
	check 'двоичный файл совпадает' same bin.dat "$sdir/ref/bin.dat"
	check 'файл без перевода строки в конце совпадает' same nonl.txt "$sdir/ref/nonl.txt"
	check 'созданный опытом файл удалён' gone new/deep/er/created.txt
	check 'созданные опытом каталоги удалены' gone new
	check 'созданный файл в существующем каталоге удалён' gone 'dir with space/fresh.txt'
	check 'существовавший каталог остался' test -d 'dir with space'
	check 'посторонний файл не тронут' test -f unrelated.txt
	check 'итог печатается по каждому файлу' out_has 'возвращён, сверен: bin.dat'
	sm status
	check 'после успеха состояние снято' out_has 'Ничего не сохранено'
	sm save a.txt
	check 'после успеха можно начинать новый опыт' rc_zero
	sm restore
}

scenario_b2_mismatch() {
	echo 'Б2: расхождение и невозможность вернуть'
	new_scenario
	make_fixtures
	sm save a.txt nonl.txt
	printf 'BAD' >a.txt

	# Подделка cp: сообщает успех, но кладёт другое содержимое.
	mkdir "$sdir/fakebin"
	cat >"$sdir/fakebin/cp" <<'EOF'
#!/bin/sh
for last; do :; done
printf 'junk' >"$last"
exit 0
EOF
	chmod +x "$sdir/fakebin/cp"
	out=$(PATH=$sdir/fakebin:$PATH "$SM_SHELL" "$helper" restore 2>&1)
	rc=$?
	check 'сверка не сошлась: ненулевой код' rc_nonzero
	check 'расхождение названо в выводе' out_has 'НЕ СОШЛОСЬ'
	sm status
	check 'состояние осталось после неудачи' out_has 'a.txt'
	sm save nonl.txt
	check 'при оставшемся состоянии сохранение по-прежнему отказывает' rc_nonzero
	sm restore
	check 'повторный возврат настоящим cp проходит' rc_zero
	check 'после него файл совпадает с эталоном' same a.txt "$sdir/ref/a.txt"

	sm save a.txt
	rm a.txt
	mkdir a.txt
	sm restore
	check 'каталог на месте файла: ненулевой код' rc_nonzero
	check 'каталог не удалён молча' test -d a.txt
	rmdir a.txt
	sm restore
	check 'после устранения помехи возврат проходит' rc_zero
	check 'файл совпадает с эталоном' same a.txt "$sdir/ref/a.txt"
}

scenario_b3() {
	echo 'Б3: ошибки входа'
	new_scenario
	make_fixtures
	sm restore
	check 'возврат без сохранения: ненулевой код' rc_nonzero
	check 'сообщение говорит, что сохранять было нечего' out_has 'ничего не сохранено'
	sm save
	check 'save без аргументов: код 2' test "$rc" -eq 2
	sm bogus
	check 'неизвестная подкоманда: код 2' test "$rc" -eq 2

	mkdir "$sdir/outside"
	printf 'precious' >"$sdir/outside/f.txt"
	sm save "$sdir/outside/f.txt"
	check 'путь вне корня (абсолютный): отказ' rc_nonzero
	sm save ../outside/f.txt
	check 'путь вне корня через ..: отказ' rc_nonzero
	sm save a.txt ../outside/f.txt
	check 'один годный и один чужой: отказ целиком' rc_nonzero
	sm restore
	check 'после отказа состояния нет' rc_nonzero
	check 'файл вне корня цел' test -f "$sdir/outside/f.txt"

	ln -s "$sdir/outside/f.txt" link.txt
	sm save link.txt
	check 'символическая ссылка: отказ' rc_nonzero
	ln -s "$sdir/outside" linkdir
	sm save linkdir/new.txt
	check 'путь через ссылку на каталог вне корня: отказ' rc_nonzero
	sm save 'dir with space'
	check 'каталог: отказ' rc_nonzero
	check 'файл вне корня по-прежнему цел' test -f "$sdir/outside/f.txt"

	sm save a.txt
	check 'после отказов сохранение работает' rc_zero
	sm save a.txt a.txt ./a.txt
	check 'при сохранённом состоянии отказ действует и для повторов' rc_nonzero
	sm restore
	check 'возврат после отказов проходит' rc_zero

	sm save made.txt
	check 'несуществующий файл сохраняется как отсутствовавший' rc_zero
	check 'сообщение называет это' out_has 'отсутствует'
	printf 'made by experiment' >made.txt
	sm restore
	check 'возврат удаляет его' rc_zero
	check 'файл удалён' gone made.txt

	sm save a.txt
	sm save a.txt
	check 'save дважды подряд: второй отказ' rc_nonzero
	sm restore
}

scenario_b4() {
	echo 'Б4: копии вне рабочего дерева'
	if ! command -v git >/dev/null 2>&1; then
		bad 'git недоступен, сценарий Б4 не выполнен'
		return
	fi
	new_scenario
	git init -q . || {
		bad 'git init не удался'
		return
	}
	make_fixtures
	git add -A
	git -c user.name=t -c user.email=t@t commit -q -m init || {
		bad 'git commit не удался'
		return
	}
	mkdir -p sub
	before=$(git status --porcelain)
	check 'исходное дерево чистое' test -z "$before"

	cd sub || exit 1
	sm save ../a.txt ../nonl.txt ../extra/new.txt
	check 'save из подкаталога: корень — корень репозитория' rc_zero
	cd "$proj" || exit 1
	check 'каталог копий не внутри проекта' test -z "$(find "$proj" -name 'safe-mutation*' -print)"
	after_save=$(git status --porcelain)
	check 'git status после save ничего нового не видит' test "$after_save" = "$before"

	printf 'BAD' >a.txt
	mkdir extra
	printf 'junk' >extra/new.txt
	sm restore
	check 'restore из корня видит то же состояние' rc_zero
	after=$(git status --porcelain)
	check 'git status после опыта пуст' test "$after" = "$before"
	check 'созданный каталог удалён' gone extra
	check 'a.txt совпадает с эталоном' same a.txt "$sdir/ref/a.txt"

	# TMPDIR внутри проекта запрещён.
	mkdir inner-tmp
	out=$(TMPDIR=$proj/inner-tmp "$SM_SHELL" "$helper" save a.txt 2>&1)
	rc=$?
	check 'TMPDIR внутри проекта: отказ' rc_nonzero
	check 'ничего не создано внутри проекта' test -z "$(ls -A inner-tmp)"
}

scenario_projects() {
	echo 'Изоляция: два проекта с одним именем каталога'
	new_scenario
	mkdir -p "$sdir/x/same" "$sdir/y/same"
	printf 'one' >"$sdir/x/same/f"
	printf 'two' >"$sdir/y/same/f"
	cd "$sdir/x/same" || exit 1
	sm save f
	check 'первый проект сохраняет' rc_zero
	cd "$sdir/y/same" || exit 1
	sm save f
	check 'второй проект не блокируется первым' rc_zero
	printf 'BAD' >f
	sm restore
	check 'второй возвращает своё' rc_zero
	check 'содержимое второго' test "$(cat f)" = two
	cd "$sdir/x/same" || exit 1
	sm status
	check 'состояние первого осталось' out_has 'f'
	sm restore
	check 'первый возвращает своё' rc_zero
}

# Помощник зовут по пути, без sh впереди: команда «sh путь» в переменной не разбивается
# на слова в zsh, и save из неё молча не выполняется.
scenario_direct() {
	echo 'Прямой вызов: помощник исполняемый и работает по пути'
	new_scenario
	check 'файл помощника исполняемый' test -x "$helper"
	out=$("$helper" help 2>&1)
	rc=$?
	check 'вызов по пути без sh' rc_zero
	check 'вызов по пути печатает справку' out_has 'save'
	if command -v zsh >/dev/null 2>&1; then
		out=$(zsh -c 'M=$1; $M help' zsh "$helper" 2>&1)
		rc=$?
		check 'вызов из переменной в zsh' rc_zero
	fi
}

scenario_b1
scenario_b2
scenario_b2_mismatch
scenario_b3
scenario_b4
scenario_projects
scenario_direct

cd "$t" || exit 1
if [ -s "$results" ]; then
	printf '\nПАДЕНИЯ (%s):\n' "$(wc -l <"$results" | tr -d ' ')"
	cat "$results"
	exit 1
fi
printf '\nВсе проверки прошли.\n'
