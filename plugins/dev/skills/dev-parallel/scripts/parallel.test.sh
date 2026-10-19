#!/bin/sh
# Сценарный тест parallel.sh. Работает только во временных каталогах: git
# настоящий, а orca, gh и claude подменены заглушками, которые ведут состояние
# PR и терминалов в файлах и сливают PR настоящим merge в пустой origin.
#
#   sh parallel.test.sh
#
# Выход: 0 — все проверки прошли, 1 — хотя бы одна упала.

set -u

here=$(cd "$(dirname "$0")" && pwd -P) || exit 1
helper=$here/parallel.sh

t=$(mktemp -d "${TMPDIR:-/tmp}/parallel-test.XXXXXX") || exit 1
t=$(cd "$t" && pwd -P)
trap 'rm -rf "$t"' EXIT INT TERM
results=$t/failures
: >"$results"
scenario_no=0

# Чужие настройки git не должны влиять на прогон.
: >"$t/gitconfig"
GIT_CONFIG_GLOBAL=$t/gitconfig
GIT_CONFIG_NOSYSTEM=1
GIT_AUTHOR_NAME=Test
GIT_AUTHOR_EMAIL=test@example.test
GIT_COMMITTER_NAME=Test
GIT_COMMITTER_EMAIL=test@example.test
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL \
	GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
DEV_PARALLEL_POLL=0
DEV_PARALLEL_WATCH_POLL=0
DEV_PARALLEL_CI_GRACE=0
DEV_PARALLEL_CI_TIMEOUT=60
DEV_PARALLEL_TERMINAL_WAIT=0
DEV_PARALLEL_SESSION_WAIT=10
export DEV_PARALLEL_POLL DEV_PARALLEL_WATCH_POLL DEV_PARALLEL_CI_GRACE DEV_PARALLEL_CI_TIMEOUT DEV_PARALLEL_TERMINAL_WAIT \
	DEV_PARALLEL_SESSION_WAIT

mkdir "$t/bin"

cat >"$t/bin/orca" <<'STUB'
#!/bin/sh
# Заглушка orca: worktree создаются git worktree add с веткой под префиксом,
# как у Orca; вызовы пишутся в $STUB/orca.log. С ORCA_STUB_RUN команда, набранная
# в терминале, выполняется в фоне в каталоге worktree, как в оболочке терминала,
# но только первые 1024 байта, как в терминале, оболочка которого ещё загружается;
# с ORCA_STUB_BROKEN orca не работает даже на --version.
printf '%s\n' "$*" >>"$STUB/orca.log"
if [ "${1:-}" = --version ]; then
	[ -z "${ORCA_STUB_BROKEN:-}" ] || { echo 'Orca.app не найдена' >&2; exit 1; }
	echo 1.0.0
	exit 0
fi
arg() {
	want=$1
	shift
	while [ $# -gt 0 ]; do
		if [ "$1" = "$want" ]; then
			printf '%s' "$2"
			return
		fi
		shift
	done
}
# run ПУТЬ КОМАНДА: выполнить набранную команду, не держа вывод вызова orca.
run() {
	[ -n "${ORCA_STUB_RUN:-}" ] || return 0
	typed=$(printf '%s' "$2" | head -c 1024)
	(cd "$1" && exec sh -c "$typed") </dev/null >/dev/null 2>&1 &
}
case "$1 $2" in
'worktree create')
	name=$(arg --name "$@")
	ref=$(arg --base-branch "$@")
	path=$STUB/ws/$name
	git worktree add -q -b "belkinsrc/$name" "$path" "$ref" >/dev/null 2>&1 ||
		{ echo '{"ok":false}'; exit 1; }
	[ -n "${ORCA_STUB_NO_TERMINAL:-}" ] || printf 'term_%s\t%s\n' "$name" "$path" >>"$STUB/terminals"
	jq -n --arg p "$path" '{ok: true, result: {worktree: {path: $p}}}'
	;;
'terminal list')
	path=$(arg --worktree "$@")
	path=${path#path:}
	handle=$(awk -F '\t' -v p="$path" '$2 == p { print $1 }' "$STUB/terminals" 2>/dev/null | head -1)
	if [ -n "$handle" ]; then
		jq -n --arg h "$handle" '{ok: true, result: {terminals: [{handle: $h}]}}'
	else
		echo '{"ok":true,"result":{"terminals":[]}}'
	fi
	;;
'terminal send')
	text=$(arg --text "$@")
	printf '%s\n' "$text" >>"$STUB/sent"
	handle=$(arg --terminal "$@")
	run "$(awk -F '\t' -v h="$handle" '$1 == h { print $2 }' "$STUB/terminals")" "$text"
	echo '{"ok":true}'
	;;
'terminal create')
	text=$(arg --command "$@")
	printf '%s\n' "$text" >>"$STUB/created"
	path=$(arg --worktree "$@")
	run "${path#path:}" "$text"
	echo '{"ok":true}'
	;;
'worktree rm')
	path=$(arg --worktree "$@")
	path=${path#path:}
	b=$(git -C "$path" symbolic-ref --short HEAD)
	git worktree remove "$path" || { echo '{"ok":false}'; exit 1; }
	git merge-base --is-ancestor "$b" origin/main 2>/dev/null && git branch -D "$b" >/dev/null
	echo '{"ok":true,"result":{"removed":true}}'
	;;
*)
	echo '{"ok":false}'
	exit 1
	;;
esac
STUB

cat >"$t/bin/gh" <<'STUB'
#!/bin/sh
# Заглушка gh: PR — строки «номер<TAB>ветка<TAB>состояние» в $STUB/prs,
# итог проверок — файл $STUB/checks, первые $STUB/pending вызовов отвечают
# «pending», описание PR — файл $STUB/body-<номер>. Слияние делается настоящим
# merge-коммитом в $ORIGIN. Пока есть файл $STUB/down, GitHub не отвечает.
printf '%s\n' "$*" >>"$STUB/gh.log"
[ "${1:-}" != --version ] || { echo 'gh version 2.0.0'; exit 0; }
[ ! -f "$STUB/down" ] || exit 1
prs=$STUB/prs
touch "$prs"
arg() {
	want=$1
	shift
	while [ $# -gt 0 ]; do
		if [ "$1" = "$want" ]; then
			printf '%s' "$2"
			return
		fi
		shift
	done
}
branch_of() { awk -F '\t' -v n="$1" '$1 == n { print $2 }' "$prs"; }
state_of() { awk -F '\t' -v n="$1" '$1 == n { print $3 }' "$prs"; }
set_state() {
	awk -F '\t' -v OFS='\t' -v n="$1" -v s="$2" '$1 == n { $3 = s } { print }' "$prs" >"$prs.new" &&
		mv "$prs.new" "$prs"
}
case "$1 $2" in
'pr list')
	b=$(arg --head "$@")
	awk -F '\t' -v OFS='\t' -v b="$b" '$2 == b { print $1, $3, "https://example.test/pull/" $1 }' "$prs" |
		sort -rn
	;;
'pr view')
	case $(arg --json "$@") in
	headRefOid) git --git-dir="$ORIGIN" rev-parse "refs/heads/$(branch_of "$3")" ;;
	state) state_of "$3" ;;
	body) cat "$STUB/body-$3" 2>/dev/null ;;
	esac
	;;
'pr checks')
	n=$(cat "$STUB/pending" 2>/dev/null || echo 0)
	if [ "$n" -gt 0 ]; then
		echo $((n - 1)) >"$STUB/pending"
		printf 'pending\tci\thttps://example.test/run\n'
	elif [ -f "$STUB/checks" ]; then
		cat "$STUB/checks"
	fi
	;;
'pr merge')
	n=$3
	b=$(branch_of "$n")
	want=$(arg --match-head-commit "$@")
	have=$(git --git-dir="$ORIGIN" rev-parse "refs/heads/$b")
	[ "$want" = "$have" ] || { echo "head mismatch: $want != $have" >&2; exit 1; }
	c=$STUB/merge-clone
	rm -rf "$c"
	git clone -q "$ORIGIN" "$c" &&
		git -C "$c" merge -q --no-ff -m "Merge pull request #$n" "origin/$b" &&
		git -C "$c" push -q origin main || exit 1
	rm -rf "$c"
	set_state "$n" MERGED
	;;
'pr close')
	set_state "$3" CLOSED
	;;
*) exit 1 ;;
esac
STUB

cat >"$t/bin/claude" <<'STUB'
#!/bin/sh
# Заглушка claude для сессии настройки: пишет каталог запуска и аргументы,
# отмечает, был ли уже .env, и по CLAUDE_STUB_MODE сдаёт pull request и остаётся
# открытой, как интерактивная сессия, пока не появится $STUB/claude.quit (pr),
# выходит без pull request (nopr) или висит, пока жива запустившая её оболочка (hang).
[ "${1:-}" != --version ] || { echo '2.0.0 (Claude Code)'; exit 0; }
printf '%s\n' "$(pwd -P)" >"$STUB/claude.cwd"
: >"$STUB/claude.args"
for a in "$@"; do printf '%s\n' "$a" >>"$STUB/claude.args"; done
[ -f .env ] && echo yes >"$STUB/claude.env"
shell=$PPID
# stay УСЛОВИЕ: ждать, пока условие верно, но не дольше 20 секунд.
stay() {
	i=0
	while eval "$1" && [ $i -lt 100 ]; do
		sleep 0.2
		i=$((i + 1))
	done
}
case ${CLAUDE_STUB_MODE:-pr} in
pr)
	printf 'setup\n' >>setup.txt
	b=$(git symbolic-ref --short HEAD)
	git add setup.txt && git commit -qm setup && git push -q -u origin "$b" || exit 1
	n=$(($(wc -l <"$STUB/prs") + 1))
	printf 'Отчёт настройки\n' >"$STUB/body-$n"
	printf '%s\t%s\tOPEN\n' "$n" "$b" >>"$STUB/prs"
	stay '[ ! -f "$STUB/claude.quit" ]'
	;;
nopr) ;;
hang) stay 'kill -0 "$shell" 2>/dev/null' ;;
esac
STUB

chmod +x "$t/bin/orca" "$t/bin/gh" "$t/bin/claude"
PATH=$t/bin:$PATH
export PATH

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

# ph АРГУМЕНТЫ...: запускает помощника по пути; вывод в $out, код в $rc.
ph() {
	out=$("$helper" "$@" 2>&1)
	rc=$?
}

# ph_env 'ПЕРЕМЕННАЯ=ЗНАЧЕНИЕ ...' АРГУМЕНТЫ...: то же с переменными окружения на один
# вызов. В sh присваивание перед вызовом функции остаётся в окружении и после
# неё, поэтому «VAR=x ph» протекло бы в следующие сценарии.
ph_env() {
	vars=$1
	shift
	out=$(env $vars "$helper" "$@" 2>&1)
	rc=$?
}

rc_is() { [ "$rc" -eq "$1" ]; }
out_has() { printf '%s\n' "$out" | grep -qF -- "$1"; }
gone() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
same_rev() { [ "$(git -C "$main" rev-parse "$1")" = "$(git -C "$main" rev-parse "$2")" ]; }
has_branch() { git -C "$main" show-ref --verify --quiet "refs/heads/$1"; }
origin_has() { git --git-dir="$ORIGIN" show-ref --verify --quiet "refs/heads/$1"; }
pr_state_is() { [ "$(awk -F '\t' -v n="$1" '$1 == n { print $3 }' "$STUB/prs")" = "$2" ]; }
merging() { git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null; }
no_orca_create() { ! grep -q '^worktree create' "$STUB/orca.log" 2>/dev/null; }
arg_is() { grep -qx -- "$1" "$STUB/claude.args"; }
prompt_has() { tail -n 1 "$STUB/claude.args" | grep -qF -- "$1"; }

# wait_file ФАЙЛ: дождаться файла, но не дольше 10 секунд.
wait_file() {
	i=0
	while [ ! -f "$1" ] && [ $i -lt 50 ]; do
		sleep 0.2
		i=$((i + 1))
	done
	[ -f "$1" ]
}

# session_file ЗАДАЧА ИМЯ: файл devparallel-ИМЯ в каталоге git worktree задачи.
session_file() {
	printf '%s/devparallel-%s' "$(git -C "$(wt "$1")" rev-parse --absolute-git-dir)" "$2"
}

# Каждый сценарий — пустой origin и его клон как главный worktree.
new_scenario() {
	scenario_no=$((scenario_no + 1))
	sdir=$t/s$scenario_no
	STUB=$sdir/stub
	ORIGIN=$sdir/origin.git
	main=$sdir/main
	export STUB ORIGIN
	mkdir -p "$STUB/ws"
	: >"$STUB/prs"
	git init -q --bare -b main "$ORIGIN"
	git clone -q "$ORIGIN" "$main" 2>/dev/null
	cd "$main" || exit 1
	printf '.env\nsecrets/\n' >.gitignore
	printf 'base\n' >shared.txt
	git add .gitignore shared.txt
	git commit -qm init
	git push -q origin main
	git remote set-head origin main
}

# push_upstream ФАЙЛ ТЕКСТ: кто-то другой пушит коммит в main origin.
push_upstream() {
	c=$sdir/upstream
	rm -rf "$c"
	git clone -q "$ORIGIN" "$c"
	printf '%s\n' "$2" >>"$c/$1"
	git -C "$c" add "$1"
	git -C "$c" commit -qm "upstream $1"
	git -C "$c" push -q origin main
	rm -rf "$c"
}

# wt ЗАДАЧА: путь worktree задачи по метке ветки.
wt() {
	for b in $(git -C "$main" for-each-ref --format='%(refname:short)' refs/heads); do
		if [ "$(git -C "$main" config --get "branch.$b.devparallel")" = "$1" ]; then
			git -C "$main" worktree list --porcelain |
				awk -v b="refs/heads/$b" '/^worktree / { p = substr($0, 10) } $0 == "branch " b { print p }'
		fi
	done
}

# deliver ЗАДАЧА ФАЙЛ ТЕКСТ: сессия задачи коммитит правку, пушит и открывает PR.
deliver() {
	p=$(wt "$1")
	printf '%s\n' "$3" >>"$p/$2"
	git -C "$p" add "$2"
	git -C "$p" commit -qm "task $1"
	b=$(git -C "$p" symbolic-ref --short HEAD)
	git -C "$p" push -q -u origin "$b"
	n=$(($(wc -l <"$STUB/prs") + 1))
	printf '%s\t%s\tOPEN\n' "$n" "$b" >>"$STUB/prs"
}

scenario_start_base() {
	echo 'Запуск: worktree от свежего origin/main, ветка по правилу проекта, метка задачи'
	new_scenario
	push_upstream other.txt fresh
	ph start 18 feature/18-mail
	check 'start завершился успешно' rc_is 0
	p=$(wt 18)
	check 'worktree задачи найден по метке 18' test -n "$p"
	check 'worktree стоит на свежем origin/main, а не на устаревшем локальном main' \
		same_rev "$(git -C "$p" rev-parse HEAD)" origin/main
	check 'ветка worktree называется feature/18-mail' \
		test "$(git -C "$p" symbolic-ref --short HEAD)" = feature/18-mail
	check 'ветки с префиксом Orca не осталось' sh -c '! git show-ref --verify --quiet refs/heads/belkinsrc/feature-18-mail'
}

scenario_start_copy() {
	echo 'Запуск: игнорируемые файлы копируются копией, ссылки разворачиваются'
	new_scenario
	printf 'SECRET=1\n' >"$sdir/real.env"
	ln -s "$sdir/real.env" .env
	mkdir -p secrets/nested
	printf 'session\n' >secrets/nested/telegram.session
	ph start 18 feature/18-mail --copy .env --copy secrets/ --copy .absent
	check 'start завершился успешно' rc_is 0
	p=$(wt 18)
	check '.env в worktree — обычный файл, а не ссылка' sh -c "[ -f '$p/.env' ] && [ ! -L '$p/.env' ]"
	check '.env скопирован с тем же содержимым' cmp -s "$sdir/real.env" "$p/.env"
	printf 'CHANGED=1\n' >>"$p/.env"
	check 'правка копии не меняет оригинал' sh -c "[ \"\$(cat '$sdir/real.env')\" = 'SECRET=1' ]"
	check 'каталог secrets/ скопирован целиком' cmp -s secrets/nested/telegram.session "$p/secrets/nested/telegram.session"
	check 'об отсутствующем пути сказано' out_has 'нет в главном worktree, не скопирован: .absent'
	check 'копии не видны git как изменения' test -z "$(git -C "$p" status --porcelain)"
}

scenario_start_refuse_tracked() {
	echo 'Запуск: путь, который git не игнорирует, не копируется, и worktree не создаётся'
	new_scenario
	ph start 18 feature/18-mail --copy shared.txt
	check 'start отказал' rc_is 1
	check 'причина названа' out_has 'git не игнорирует shared.txt'
	check 'Orca worktree не создавал' no_orca_create
	check 'ветки feature/18-mail нет' sh -c '! git show-ref --verify --quiet refs/heads/feature/18-mail'
}

scenario_start_prompt() {
	echo 'Запуск: Claude получает команду dev с просьбой сдать задачу, кавычки переживают оболочку'
	new_scenario
	branch="feature/18-it's-\$(id>pwned)"
	ph start 18 "$branch"
	check 'start завершился успешно' rc_is 0
	check 'команда отправлена в терминал worktree' test -s "$STUB/sent"
	mkdir "$sdir/fake"
	cat >"$sdir/fake/claude" <<'FAKE'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done >"$ARG_FILE.all"
for a in "$@"; do last=$a; done
printf '%s' "$last" >"$ARG_FILE"
FAKE
	chmod +x "$sdir/fake/claude"
	cmd=$(tail -n 1 "$STUB/sent")
	(cd "$sdir" && ARG_FILE=$sdir/arg PATH=$sdir/fake:$PATH sh -c "$cmd")
	expected="/dev:dev 18. Сдай задачу через pull request по разделу «Сдача через pull request» скила dev: когда отчёт готов, закоммить изменения, запушь ветку $branch и открой pull request в main с отчётом в описании. Не сливай. Команда наблюдения за pull request: '$helper' watch 18"
	check 'Claude получил первую команду дословно' test "$(cat "$sdir/arg")" = "$expected"
	check 'Claude получил номер сессии из файла задачи' \
		test "$(sed -n '/^--session-id$/{n;p;}' "$sdir/arg.all")" = "$(cat "$(session_file 18 session)")"
	check 'подстановка из имени ветки не выполнилась' gone "$sdir/pwned"
}

scenario_start_no_terminal() {
	echo 'Запуск: без терминала в worktree Claude открывается новой вкладкой'
	new_scenario
	ph_env ORCA_STUB_NO_TERMINAL=1 start 18 feature/18-mail
	check 'start завершился успешно' rc_is 0
	check 'вкладка создана с запуском файла команды' \
		test "$(cat "$STUB/created")" = "sh '$(session_file 18 run)'"
	check 'в файле команды — claude с номером сессии и задачей 18' \
		grep -q "; claude --session-id [0-9a-f-]* '/dev:dev 18\\. " "$(session_file 18 run)"
}

scenario_start_session() {
	echo 'Запуск: сессия задачи видна в status, после её выхода — команда продолжения'
	new_scenario
	ph_env 'ORCA_STUB_RUN=1 CLAUDE_STUB_MODE=nopr' start 18 feature/18-mail
	check 'start завершился успешно' rc_is 0
	sid=$(cat "$(session_file 18 session)")
	check 'номер сессии назван' out_has "сессия Claude $sid"
	check 'после выхода Claude записан его код' wait_file "$(session_file 18 exit)"
	ph status
	check 'status: сессия задачи закончилась' out_has 'сессия Claude закончилась, код 0'
	check 'status: команда продолжения сессии' out_has "claude --resume $sid"
}

scenario_start_refuse_existing() {
	echo 'Запуск: ветка, которая уже есть на origin, не переиспользуется'
	new_scenario
	git push -q origin main:refs/heads/feature/18-mail
	ph start 18 feature/18-mail
	check 'start отказал' rc_is 1
	check 'причина названа' out_has 'ветка feature/18-mail уже есть на origin'
	check 'Orca worktree не создавал' no_orca_create
}

scenario_setup() {
	echo 'Настройка: интерактивная сессия Claude в терминале worktree, setup-wait ждёт pull request'
	new_scenario
	printf 'SECRET=1\n' >.env
	ph_env ORCA_STUB_RUN=1 setup parallel-setup --copy .env
	check 'setup дождался начала сессии: код 0' rc_is 0
	p=$(wt setup)
	check 'worktree помечен задачей setup' test -n "$p"
	check 'в терминале набран только запуск файла команды' \
		test "$(cat "$STUB/sent")" = "sh '$(session_file setup run)'"
	ph setup-wait
	check 'setup-wait при открытом pull request: код 0' rc_is 0
	check 'pull request назван' out_has 'Pull request #1 открыт: https://example.test/pull/1'
	check 'отчёт сессии из описания pull request показан' out_has 'Отчёт настройки'
	check 'pull request открыт' pr_state_is 1 OPEN
	check 'Claude запущен в worktree настройки' test "$(cat "$STUB/claude.cwd")" = "$p"
	check '.env скопирован до запуска Claude' test -f "$STUB/claude.env"
	check 'Claude запущен интерактивно, а не через -p' sh -c "! grep -qx -- -p '$STUB/claude.args'"
	check 'Claude запущен без вопросов о разрешениях' arg_is auto
	sid=$(sed -n '/^--session-id$/{n;p;}' "$STUB/claude.args")
	check 'Claude получил номер сессии' test -n "$sid"
	check 'задача — настройка параллельной работы через dev' \
		prompt_has '/dev:dev Настрой проект для параллельной работы дирижёра dev-parallel.'
	check 'в задаче назван главный worktree' prompt_has "$main"
	check 'согласование условия отменено явно' prompt_has 'согласовывать условие готовности не нужно'
	check 'просьба сдать через pull request без слияния' \
		prompt_has 'запушь ветку parallel-setup и открой pull request в main с отчётом в описании. Не сливай.'
	ph status
	check 'status: сессия после pull request ещё открыта' out_has 'сессия Claude идёт'
	touch "$STUB/claude.quit"
	check 'после выхода Claude записан его код' wait_file "$(session_file setup exit)"
	ph status
	check 'status: сессия закончилась' out_has 'сессия Claude закончилась, код 0'
}

scenario_setup_unfinished() {
	echo 'Настройка: сессия вышла или терминал закрыт без pull request — код 6, worktree остаётся'
	new_scenario
	ph_env 'ORCA_STUB_RUN=1 CLAUDE_STUB_MODE=nopr' setup parallel-setup
	check 'setup дождался начала сессии: код 0' rc_is 0
	sid=$(printf '%s\n' "$out" | sed -n 's/^Сессия настройки \([^ ]*\) идёт.*/\1/p')
	wait_file "$(session_file setup exit)"
	ph setup-wait
	check 'Claude вышел без pull request: код 6' rc_is 6
	check 'сказано, как закончилась сессия' out_has 'Claude вышел с кодом 0'
	check 'номер сессии тот же, что получил Claude' \
		test "$sid" = "$(sed -n '/^--session-id$/{n;p;}' "$STUB/claude.args")"
	check 'показано, как продолжить сессию' out_has "claude --resume $sid"
	check 'worktree настройки оставлен' test -d "$(wt setup)"

	new_scenario
	ph_env 'ORCA_STUB_RUN=1 CLAUDE_STUB_MODE=hang' setup parallel-setup
	ph status
	check 'status: сессия идёт' out_has 'сессия Claude идёт'
	kill "$(cat "$(session_file setup pid)")"
	ph setup-wait
	check 'терминал закрыт без pull request: код 6' rc_is 6
	check 'сказано, что терминал закрыт' out_has 'терминал сессии закрыт'
	check 'worktree настройки оставлен' test -d "$(wt setup)"
	ph status
	check 'status: сессия оборвалась' out_has 'сессия Claude оборвалась: терминал закрыт'

	new_scenario
	ph_env DEV_PARALLEL_SESSION_WAIT=0 setup parallel-setup
	check 'команда в терминале не началась: код 1' rc_is 1
	check 'причина названа' out_has 'не началась'
	check 'worktree настройки оставлен' test -d "$(wt setup)"
	ph setup-wait
	check 'setup-wait без начатой сессии: код 1' rc_is 1
	ph status
	check 'status: сессия не началась' out_has 'сессия Claude не началась'
}

scenario_need_broken() {
	echo 'Проверка команд: неработающая orca останавливает setup до любых действий'
	new_scenario
	ph_env ORCA_STUB_BROKEN=1 setup parallel-setup
	check 'setup отказал' rc_is 1
	check 'названа неработающая команда' out_has 'команда orca не работает'
	check 'Orca worktree не создавал' no_orca_create
	check 'ветки parallel-setup нет' sh -c '! git show-ref --verify --quiet refs/heads/parallel-setup'
}

scenario_home() {
	echo 'Главный worktree: чужая ветка и изменения останавливают, иначе перемотка'
	new_scenario
	git switch -q -c docs-cleanup
	ph home
	check 'на чужой ветке home отказал' rc_is 1
	check 'ветку home не переключил' test "$(git symbolic-ref --short HEAD)" = docs-cleanup
	git switch -q main
	printf 'local\n' >>shared.txt
	ph home
	check 'с незакоммиченной правкой home отказал' rc_is 1
	git checkout -q -- shared.txt
	push_upstream other.txt fresh
	ph home
	check 'чистый main подтянут' rc_is 0
	check 'main совпадает с origin/main' same_rev HEAD origin/main
}

# set_pr НОМЕР СОСТОЯНИЕ: PR сливают или закрывают снаружи.
set_pr() {
	awk -F '\t' -v OFS='\t' -v n="$1" -v s="$2" '$1 == n { $3 = s } { print }' "$STUB/prs" >"$STUB/prs.new" &&
		mv "$STUB/prs.new" "$STUB/prs"
}

# bg ИМЯ АРГУМЕНТЫ...: помощник в фоне; вывод — в $sdir/ИМЯ.out, код — в $sdir/ИМЯ.rc.
bg() {
	bname=$1
	shift
	rm -f "$sdir/$bname.out" "$sdir/$bname.rc"
	("$helper" "$@" >"$sdir/$bname.out" 2>&1
	echo $? >"$sdir/$bname.rc") &
}

# still ИМЯ: фоновый помощник через секунду ещё не вернулся.
still() {
	sleep 1
	[ ! -f "$sdir/$1.rc" ]
}

# bg_done ИМЯ КОД: фоновый помощник вернулся с этим кодом; вывод — в $out.
bg_done() {
	wait_file "$sdir/$1.rc" || return 1
	out=$(cat "$sdir/$1.out")
	[ "$(cat "$sdir/$1.rc")" = "$2" ]
}

scenario_watch() {
	echo 'Наблюдение: красный CI на коммите ветки, слитый и закрытый PR; зелёный, чужой коммит и сбой GitHub — ждать'
	new_scenario
	ph start 18 feature/18-mail
	deliver 18 mail.txt 'task 18'
	p=$(wt 18)
	head=$(git -C "$p" rev-parse HEAD)
	printf 'pass\tlint\thttps://example.test/1\nfail\ttests\thttps://example.test/2\n' >"$STUB/checks"
	ph watch 18
	check 'красный CI: код 4' rc_is 4
	check 'упавшая проверка названа' out_has 'tests https://example.test/2'
	check 'назван коммит' out_has "CI красный на коммите $head"
	printf 'cancel\tci\thttps://example.test/3\n' >"$STUB/checks"
	ph watch 18
	check 'отменённая проверка — красный CI: код 4' rc_is 4
	check 'отмена помечена' out_has 'ci (отменена) https://example.test/3'

	printf 'fix\n' >>"$p/mail.txt"
	git -C "$p" commit -qam fix
	bg watch watch 18
	check 'красный итог коммита, которого уже нет в ветке, не возвращает' still watch
	git -C "$p" push -q origin HEAD
	check 'после push красный CI на коммите ветки: код 4' bg_done watch 4

	printf 'pass\tci\thttps://example.test/run\n' >"$STUB/checks"
	bg watch watch 18
	check 'зелёный CI не возвращает' still watch
	touch "$STUB/down"
	check 'сбой GitHub не возвращает' still watch
	rm "$STUB/down"
	set_pr 1 MERGED
	check 'слитый PR: код 0' bg_done watch 0
	check 'сказано, что PR слит' out_has 'PR #1 слит'
	set_pr 1 CLOSED
	ph watch 18
	check 'закрытый PR: код 0' rc_is 0
	check 'сказано, что PR закрыт' out_has 'PR #1 закрыт без слияния'
}

scenario_wait() {
	echo 'Ожидание починки: зелёный CI — код 0, сессия закончилась при красном — код 6'
	new_scenario
	ph_env 'ORCA_STUB_RUN=1 CLAUDE_STUB_MODE=hang' start 18 feature/18-mail
	wait_file "$(session_file 18 pid)"
	deliver 18 mail.txt 'task 18'
	printf 'fail\ttests\thttps://example.test/2\n' >"$STUB/checks"
	bg wait wait 18
	check 'красный CI при идущей сессии не возвращает' still wait
	printf 'pending\tci\thttps://example.test/run\n' >"$STUB/checks"
	check 'идущий CI не возвращает' still wait
	printf 'pass\tci\thttps://example.test/run\n' >"$STUB/checks"
	check 'зелёный CI: код 0' bg_done wait 0
	check 'назван зелёный коммит' out_has "CI зелёный на коммите $(git -C "$(wt 18)" rev-parse HEAD)"

	printf 'pending\tci\thttps://example.test/run\n' >"$STUB/checks"
	sid=$(cat "$(session_file 18 session)")
	kill "$(cat "$(session_file 18 pid)")"
	bg wait wait 18
	check 'после конца сессии идущий CI ещё дожидаются' still wait
	printf 'fail\ttests\thttps://example.test/2\n' >"$STUB/checks"
	check 'сессии нет, CI красный: код 6' bg_done wait 6
	check 'сказано, как закончилась сессия' out_has 'терминал сессии закрыт'
	check 'упавшая проверка названа' out_has 'tests https://example.test/2'
	check 'показано, как продолжить сессию' out_has "claude --resume $sid"

	rm "$(session_file 18 session)"
	bg wait wait 18
	check 'без сведений о сессии ждётся только зелёный CI' still wait
	set_pr 1 CLOSED
	check 'закрытый PR: код 1' bg_done wait 1
	check 'причина названа' out_has 'в состоянии CLOSED'
}

scenario_sync() {
	echo 'Вливание main: без изменений, чисто, с конфликтом'
	new_scenario
	ph start 18 feature/18-mail
	deliver 18 mail.txt 'task 18'
	p=$(wt 18)
	before=$(git -C "$p" rev-parse HEAD)
	ph sync 18 'Слить main в ветку задачи 18'
	check 'ветка уже содержит main: код 0' rc_is 0
	check 'коммита не появилось' test "$(git -C "$p" rev-parse HEAD)" = "$before"

	push_upstream other.txt fresh
	ph sync 18 'Слить main в ветку задачи 18'
	check 'чистое вливание: код 0' rc_is 0
	check 'origin/main вошёл в ветку' git -C "$p" merge-base --is-ancestor origin/main HEAD
	check 'merge-коммит с данным сообщением' \
		test "$(git -C "$p" log -1 --format=%s)" = 'Слить main в ветку задачи 18'

	git -C "$p" push -q origin HEAD
	printf 'task side\n' >>"$p/shared.txt"
	git -C "$p" commit -qam 'task edits shared'
	git -C "$p" push -q origin HEAD
	push_upstream shared.txt 'main side'
	ph sync 18 'Слить main в ветку задачи 18'
	check 'конфликт: код 3' rc_is 3
	check 'слияние оставлено незавершённым' merging "$p"
	check 'файл с конфликтом назван' out_has shared.txt
	ph sync 18 'Слить main в ветку задачи 18'
	check 'повторный sync посреди слияния отказал' rc_is 1
}

scenario_sync_refusals() {
	echo 'Вливание main: работа сессии не закончена — отказ'
	new_scenario
	ph start 18 feature/18-mail
	push_upstream other.txt fresh
	ph sync 18 'Слить main'
	check 'без PR sync отказал' rc_is 1
	deliver 18 mail.txt 'task 18'
	p=$(wt 18)
	printf 'wip\n' >>"$p/mail.txt"
	ph sync 18 'Слить main'
	check 'с незакоммиченной правкой sync отказал' rc_is 1
	check 'слияние не начато' sh -c "! git -C '$p' rev-parse -q --verify MERGE_HEAD >/dev/null"
	git -C "$p" commit -qam 'more work'
	ph sync 18 'Слить main'
	check 'с незапушенным коммитом sync отказал' rc_is 1
	check 'причина названа' out_has 'расходится с origin'
}

scenario_land_green() {
	echo 'Слияние PR: push, зелёный CI на этом коммите, merge-коммит'
	new_scenario
	ph start 18 feature/18-mail
	deliver 18 mail.txt 'task 18'
	p=$(wt 18)
	push_upstream other.txt fresh
	ph land 18
	check 'отставшая ветка не сливается' rc_is 1
	check 'PR остался открытым' pr_state_is 1 OPEN

	"$helper" sync 18 'Слить main в ветку задачи 18' >/dev/null 2>&1
	head=$(git -C "$p" rev-parse HEAD)
	printf 'pass\tci\thttps://example.test/run\n' >"$STUB/checks"
	echo 2 >"$STUB/pending"
	ph land 18
	check 'land завершился успешно' rc_is 0
	check 'merge-коммит sync запушен перед CI' test "$(git --git-dir="$ORIGIN" rev-parse refs/heads/feature/18-mail)" = "$head"
	check 'CI ждали, пока он шёл' test "$(cat "$STUB/pending")" = 0
	check 'слит именно проверенный коммит' grep -qF -- "--merge --match-head-commit $head" "$STUB/gh.log"
	check 'PR слит' pr_state_is 1 MERGED
	check 'коммит ветки вошёл в main на origin' \
		git --git-dir="$ORIGIN" merge-base --is-ancestor "$head" refs/heads/main
}

scenario_land_red() {
	echo 'Слияние PR: красный CI и CI без проверок не сливаются'
	new_scenario
	ph start 18 feature/18-mail
	deliver 18 mail.txt 'task 18'
	printf 'pass\tlint\thttps://example.test/1\nfail\ttests\thttps://example.test/2\n' >"$STUB/checks"
	ph land 18
	check 'красный CI: код 4' rc_is 4
	check 'упавшая проверка названа' out_has 'tests https://example.test/2'
	check 'PR остался открытым' pr_state_is 1 OPEN
	rm "$STUB/checks"
	ph land 18
	check 'без проверок: код 5' rc_is 5
	check 'PR остался открытым' pr_state_is 1 OPEN
	printf 'skipping\tpublish\thttps://example.test/3\n' >"$STUB/checks"
	ph land 18
	check 'только пропущенные проверки — не зелёный: код 5' rc_is 5
	ph land 18 --without-ci
	check 'с --without-ci слит без CI' rc_is 0
	check 'PR слит' pr_state_is 1 MERGED
}

scenario_remove() {
	echo 'Уборка: слитая задача убирается целиком, неслитая — только с --cancel'
	new_scenario
	ph start 18 feature/18-mail
	ph start 20 feature/20-ops
	deliver 18 mail.txt 'task 18'
	deliver 20 ops.txt 'task 20'
	p18=$(wt 18)
	p20=$(wt 20)
	printf 'pass\tci\thttps://example.test/run\n' >"$STUB/checks"
	"$helper" land 18 >/dev/null 2>&1
	ph remove 18
	check 'remove слитой задачи успешен' rc_is 0
	check 'worktree удалён' gone "$p18"
	check 'локальная ветка удалена' sh -c '! git show-ref --verify --quiet refs/heads/feature/18-mail'
	check 'ветка на origin удалена' sh -c "! git --git-dir='$ORIGIN' show-ref --verify --quiet refs/heads/feature/18-mail"

	ph remove 20
	check 'неслитая задача без --cancel не убирается' rc_is 1
	check 'worktree на месте' test -d "$p20"
	printf 'wip\n' >>"$p20/ops.txt"
	ph remove 20 --cancel
	check 'с незакоммиченной правкой не убирается даже с --cancel' rc_is 1
	git -C "$p20" checkout -q -- ops.txt
	head20=$(git -C "$p20" rev-parse HEAD)
	ph remove 20 --cancel
	check 'remove --cancel успешен' rc_is 0
	check 'PR закрыт' pr_state_is 2 CLOSED
	check 'worktree удалён' gone "$p20"
	check 'локальная ветка оставлена на том же коммите' same_rev feature/20-ops "$head20"
	check 'ветка на origin оставлена' origin_has feature/20-ops
	check 'метка задачи снята' sh -c '! git config --get branch.feature/20-ops.devparallel'
	ph status
	check 'задач в worktree не осталось' out_has 'Задач в worktree нет.'
}

scenario_status() {
	echo 'Состояние: PR, CI и общие изменённые файлы'
	new_scenario
	ph start 18 feature/18-mail
	ph start 20 feature/20-ops
	deliver 18 shared.txt 'task 18'
	printf 'task 20\n' >>"$(wt 20)/shared.txt"
	printf 'pending\tci\thttps://example.test/run\n' >"$STUB/checks"
	ph status
	check 'status успешен' rc_is 0
	check 'PR задачи 18 и идущий CI показаны' out_has 'PR #1 https://example.test/pull/1, CI идёт'
	check 'незакоммиченная правка задачи 20 показана' out_has 'файлов с незакоммиченными изменениями: 1'
	check 'общий файл задач 18 и 20 назван' out_has '18 и 20: shared.txt'
}

scenario_start_base
scenario_start_copy
scenario_start_refuse_tracked
scenario_start_prompt
scenario_start_no_terminal
scenario_start_session
scenario_start_refuse_existing
scenario_setup
scenario_setup_unfinished
scenario_need_broken
scenario_home
scenario_watch
scenario_wait
scenario_sync
scenario_sync_refusals
scenario_land_green
scenario_land_red
scenario_remove
scenario_status

if [ -s "$results" ]; then
	printf '\nУпало проверок: %s\n' "$(wc -l <"$results" | tr -d ' ')"
	exit 1
fi
printf '\nВсе проверки прошли.\n'
