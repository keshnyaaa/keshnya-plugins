#!/bin/sh
# Помощник дирижёра dev-parallel: worktree задач в Orca, наблюдение за их PR, очередь
# слияния и уборка.
#
#   parallel.sh home                        проверить, что главный worktree стоит на основной
#                                           ветке без изменений, и подтянуть её
#   parallel.sh start ЗАДАЧА ВЕТКА [--copy ПУТЬ]...
#                                           создать worktree задачи от свежей основной ветки,
#                                           скопировать в него файлы из главного, запустить Claude
#   parallel.sh setup ВЕТКА [--copy ПУТЬ]...
#                                           то же для задачи настройки параллельной работы,
#                                           но Claude идёт без человека; помощник возвращается,
#                                           когда сессия началась
#   parallel.sh setup-wait                  ждать, пока сессия настройки откроет pull request
#                                           или закончится
#   parallel.sh status                      задачи в worktree: изменения, сессия, PR, CI, общие файлы
#   parallel.sh watch ЗАДАЧА                для сессии задачи: ждать, пока CI на последнем коммите
#                                           её ветки покраснеет или её PR сольют или закроют
#   parallel.sh sync ЗАДАЧА СООБЩЕНИЕ       влить свежую основную ветку в ветку задачи
#   parallel.sh land ЗАДАЧА [--without-ci]  запушить ветку, дождаться зелёного CI на её коммите
#                                           и слить PR merge-коммитом
#   parallel.sh wait ЗАДАЧА                 ждать, пока CI на PR задачи станет зелёным или её
#                                           сессия закончится
#   parallel.sh remove ЗАДАЧА [--cancel]    убрать worktree слитой задачи; с --cancel — отменённой:
#                                           PR закрывается, ветки остаются
#   parallel.sh help                        эта справка
#
# Файл исполняемый: зови его по пути, без sh.
#
# Запускается из любого worktree проекта. Главный worktree — первый в списке
# git worktree list, основная ветка — та, на которую указывает origin/HEAD.
# Worktree задачи помечен настройкой git branch.<ветка>.devparallel с номером
# задачи, и остальные команды находят задачу по ней.
#
# start и setup копируют только пути, которые git игнорирует, и только копией:
# символические ссылки разворачиваются, а файл, который в worktree уже есть,
# не перезаписывается. Push всегда обычный, без --force.
#
# start и setup запускают Claude в терминале Orca. Команду запуска помощник кладёт
# в каталог git worktree (devparallel-run), а в терминале набирает только короткое
# sh с путём к ней. Терминал нового worktree может принять ввод раньше, чем его
# оболочка загрузилась, и тогда строка длиннее 1024 байт обрезается, а задача
# настройки длиннее.
#
# Команда запуска — обёртка вокруг claude с номером сессии: она пишет в каталог git
# worktree номер своего процесса (devparallel-pid), а после выхода Claude — его код
# (devparallel-exit); номер сессии лежит там же (devparallel-session). По этим
# файлам setup-wait, wait и status узнают, идёт ли сессия. У задачи, которую
# помощник так не запускал, wait ждёт только зелёного CI.
#
# Просьба к сессии задачи называет команду watch: сессия держит её фоновой и чинит
# красный CI своего PR, пока его не сольют или не закроют, в том числе после sync.
# Красным watch считает CI только на коммите, который стоит и в ветке, и в PR.
#
# Нужны git, gh, jq, orca и claude, и каждая должна отвечать на --version;
# номер сессии Claude даёт uuidgen. Пауза между опросами GitHub —
# DEV_PARALLEL_POLL секунд (20), у watch — DEV_PARALLEL_WATCH_POLL (60), ожидание
# первых проверок — DEV_PARALLEL_CI_GRACE (300), предел ожидания итога CI —
# DEV_PARALLEL_CI_TIMEOUT (3600), ожидание терминала нового worktree —
# DEV_PARALLEL_TERMINAL_WAIT (10), ожидание начала сессии настройки —
# DEV_PARALLEL_SESSION_WAIT (60).
# Выход: 0 — успех, 1 — отказ или сбой, 2 — неверный вызов, 3 — конфликт при
# sync (слияние оставлено незавершённым), 4 — CI красный, 5 — CI не дал итога,
# 6 — сессия закончилась: у setup-wait без открытого pull request, у wait — пока
# CI не зелёный.

set -u

tab=$(printf '\t')
nl=$(printf '\n.')
nl=${nl%.}

poll=${DEV_PARALLEL_POLL:-20}
watch_poll=${DEV_PARALLEL_WATCH_POLL:-60}
grace=${DEV_PARALLEL_CI_GRACE:-300}
ci_timeout=${DEV_PARALLEL_CI_TIMEOUT:-3600}
terminal_wait=${DEV_PARALLEL_TERMINAL_WAIT:-10}
session_wait=${DEV_PARALLEL_SESSION_WAIT:-60}

# Полный путь к помощнику: его называет просьба к сессии задачи, а setup_repo меняет каталог.
self=$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")

die() {
	printf 'parallel: %s\n' "$*" >&2
	exit 1
}

usage() {
	sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//; /^$/d'
}

bad_call() {
	usage >&2
	exit 2
}

# need КОМАНДА...: каждая команда есть и выполняется. Одного command -v мало:
# обёртка вроде orca находится, даже когда то, что она запускает, сломано.
need() {
	for tool in "$@"; do
		command -v "$tool" >/dev/null 2>&1 || die "нет команды $tool"
		"$tool" --version >/dev/null 2>&1 ||
			die "команда $tool не работает: $tool --version завершилась ошибкой"
	done
}

# Главный worktree в main_wt, основная ветка в base; текущий каталог — главный worktree.
setup_repo() {
	main_wt=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
	[ -n "$main_wt" ] || die 'запусти из репозитория проекта'
	cd "$main_wt" || die "главный worktree недоступен: $main_wt"
	origin_head=$(git symbolic-ref --short -q refs/remotes/origin/HEAD) ||
		die 'не знаю основную ветку: origin/HEAD не задан (git remote set-head origin --auto)'
	base=${origin_head#origin/}
}

check_task_id() {
	case $1 in
	'' | *[!A-Za-z0-9._-]*) die "недопустимый номер задачи: $1" ;;
	esac
}

# list_tasks: строки «задача<TAB>ветка<TAB>путь» всех worktree задач — в TASKS.
list_tasks() {
	TASKS=
	wpath=
	while read -r key val; do
		case $key in
		worktree) wpath=$val ;;
		branch)
			wbranch=${val#refs/heads/}
			wtask=$(git config --get "branch.$wbranch.devparallel") || continue
			TASKS=$TASKS$wtask$tab$wbranch$tab$wpath$nl
			;;
		esac
	done <<EOF
$(git worktree list --porcelain)
EOF
	TASKS=${TASKS%"$nl"}
}

# find_task ЗАДАЧА: путь и ветка worktree задачи — в TASK_PATH и TASK_BRANCH.
find_task() {
	check_task_id "$1"
	TASK_PATH=
	TASK_BRANCH=
	list_tasks
	while IFS=$tab read -r ftask fbranch fpath; do
		if [ "$ftask" = "$1" ]; then
			TASK_BRANCH=$fbranch
			TASK_PATH=$fpath
		fi
	done <<EOF
$TASKS
EOF
	[ -n "$TASK_PATH" ] || die "нет worktree задачи $1"
}

# dirty ПУТЬ: изменения worktree вне коммитов, без игнорируемых файлов.
dirty() {
	git -C "$1" status --porcelain
}

in_merge() {
	git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1
}

# pushed ВЕТКА: ветка на origin совпадает с локальной.
pushed() {
	[ "$(git rev-parse "refs/heads/$1")" = "$(git rev-parse -q --verify "refs/remotes/origin/$1")" ]
}

fetch() {
	git fetch --quiet origin || die 'git fetch не удался'
}

shquote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# pr_of ВЕТКА: PR ветки — открытый, а без него самый новый — в PR_NUM, PR_STATE, PR_URL.
# Код 1 — GitHub не ответил; без PR переменные пустые.
pr_of() {
	PR_NUM=
	PR_STATE=
	PR_URL=
	prs=$(gh pr list --head "$1" --state all --json number,state,url \
		--jq '.[] | [.number, .state, .url] | @tsv' 2>/dev/null) || return 1
	pick=
	while IFS=$tab read -r pnum pstate purl; do
		[ -n "$pnum" ] || continue
		[ -n "$pick" ] || pick=$pnum$tab$pstate$tab$purl
		if [ "$pstate" = OPEN ]; then
			pick=$pnum$tab$pstate$tab$purl
			break
		fi
	done <<EOF
$prs
EOF
	[ -n "$pick" ] || return 0
	IFS=$tab read -r PR_NUM PR_STATE PR_URL <<EOF
$pick
EOF
}

pr_head() {
	gh pr view "$1" --json headRefOid --jq .headRefOid 2>/dev/null
}

pr_state() {
	gh pr view "$1" --json state --jq .state 2>/dev/null
}

pr_body() {
	gh pr view "$1" --json body --jq .body 2>/dev/null
}

# session_state ПУТЬ: сессия настройки в worktree. SESSION_ID — номер сессии Claude,
# пустой, если setup её здесь не запускал. SESSION_STATE: none — команда в терминале
# не началась, running — идёт, exited — Claude вышел с кодом SESSION_CODE, gone —
# оболочка с командой исчезла раньше выхода Claude, то есть терминал закрыли.
session_state() {
	sgit=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)
	SESSION_ID=$(cat "$sgit/devparallel-session" 2>/dev/null)
	SESSION_CODE=
	spid=$(cat "$sgit/devparallel-pid" 2>/dev/null)
	# Жизнь оболочки проверяется до файла кода: оболочка пишет код перед тем, как
	# исчезнуть, поэтому мёртвая оболочка без файла кода значит закрытый терминал.
	salive=0
	[ -n "$spid" ] && kill -0 "$spid" 2>/dev/null && salive=1
	if [ -f "$sgit/devparallel-exit" ]; then
		SESSION_STATE=exited
		SESSION_CODE=$(cat "$sgit/devparallel-exit" 2>/dev/null)
	elif [ -z "$spid" ]; then
		SESSION_STATE=none
	elif [ $salive -eq 1 ]; then
		SESSION_STATE=running
	else
		SESSION_STATE=gone
	fi
}

# session_end ПУТЬ: как закончилась сессия, которая не идёт, — в SESSION_END, а команда
# её продолжения — в SESSION_RESUME.
session_end() {
	case $SESSION_STATE in
	exited) SESSION_END="Claude вышел с кодом $SESSION_CODE" ;;
	gone) SESSION_END='терминал сессии закрыт раньше, чем Claude вышел' ;;
	*) SESSION_END='команда сессии в терминале не началась' ;;
	esac
	SESSION_RESUME="cd $(shquote "$1") && claude --resume $SESSION_ID"
}

# ci_state PR: итог проверок головного коммита PR в CI_STATE (green, red, pending,
# none), упавшие и отменённые проверки — в CI_FAILED. Отменённая — по лимиту времени
# или вручную — помечена: это не падение проверки, но и не зелёный итог.
ci_state() {
	CI_FAILED=
	checks=$(gh pr checks "$1" --json bucket,name,link \
		--jq '.[] | [.bucket, .name, .link] | @tsv' 2>/dev/null)
	n_pass=0
	n_pending=0
	n_fail=0
	while IFS=$tab read -r cbucket cname clink; do
		case $cbucket in
		pass) n_pass=$((n_pass + 1)) ;;
		pending) n_pending=$((n_pending + 1)) ;;
		fail)
			n_fail=$((n_fail + 1))
			CI_FAILED="$CI_FAILED$cname $clink$nl"
			;;
		cancel)
			n_fail=$((n_fail + 1))
			CI_FAILED="$CI_FAILED$cname (отменена) $clink$nl"
			;;
		esac
	done <<EOF
$checks
EOF
	if [ $n_fail -gt 0 ]; then
		CI_STATE=red
	elif [ $n_pending -gt 0 ]; then
		CI_STATE=pending
	elif [ $n_pass -gt 0 ]; then
		CI_STATE=green
	else
		CI_STATE=none
	fi
}

elapsed_since() {
	echo $(($(date +%s) - $1))
}

# wait_head PR КОММИТ: ждать, пока PR покажет этот головной коммит.
wait_head() {
	wstart=$(date +%s)
	while [ "$(pr_head "$1")" != "$2" ]; do
		[ "$(elapsed_since "$wstart")" -lt 120 ] ||
			die "PR #$1 за 2 минуты так и не показал коммит $2"
		sleep "$poll"
	done
}

# wait_green PR КОММИТ: вернуться при зелёном CI; при красном выйти с кодом 4,
# без итога — с кодом 5.
wait_green() {
	wstart=$(date +%s)
	while :; do
		whead=$(pr_head "$1")
		if [ -n "$whead" ] && [ "$whead" != "$2" ]; then
			die "в PR #$1 появился коммит $whead, пока шёл CI на $2; повтори land"
		fi
		ci_state "$1"
		welapsed=$(elapsed_since "$wstart")
		case $CI_STATE in
		green)
			printf 'CI зелёный на коммите %s\n' "$2"
			return 0
			;;
		red)
			printf 'CI красный на коммите %s, PR #%s не слит. Упали:\n%s' "$2" "$1" "$CI_FAILED" >&2
			exit 4
			;;
		none)
			if [ "$welapsed" -ge "$grace" ]; then
				printf 'За %s с на коммите %s не появилось ни одной проверки, PR #%s не слит.\n' \
					"$grace" "$2" "$1" >&2
				exit 5
			fi
			;;
		pending)
			if [ "$welapsed" -ge "$ci_timeout" ]; then
				printf 'CI на коммите %s не закончился за %s с, PR #%s не слит.\n' \
					"$2" "$ci_timeout" "$1" >&2
				exit 5
			fi
			;;
		esac
		sleep "$poll"
	done
}

cmd_home() {
	[ $# -eq 0 ] || bad_call
	cur=$(git symbolic-ref --short -q HEAD) || die 'главный worktree не стоит на ветке'
	[ "$cur" = "$base" ] ||
		die "главный worktree на ветке $cur, а не на $base. Сам помощник его не переключает: на этой ветке может быть работа."
	changes=$(git status --porcelain --untracked-files=no)
	[ -z "$changes" ] || die "в главном worktree незакоммиченные изменения:$nl$changes"
	fetch
	git merge --ff-only --quiet "origin/$base" ||
		die "$base не подтягивается перемоткой: в главном worktree есть коммиты, которых нет на origin/$base"
	printf 'Главный worktree %s: ветка %s, коммит %s\n' \
		"$main_wt" "$base" "$(git rev-parse --short HEAD)"
}

# prepare_worktree ЗАДАЧА ВЕТКА [--copy ПУТЬ]...: создать worktree задачи от свежей
# основной ветки и скопировать в него файлы из главного; путь — в path.
prepare_worktree() {
	task=$1
	branch=$2
	shift 2
	check_task_id "$task"
	git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "недопустимое имя ветки: $branch"
	copies=
	while [ $# -gt 0 ]; do
		[ "$1" = --copy ] && [ $# -ge 2 ] || bad_call
		cpath=$2
		shift 2
		while :; do
			case $cpath in
			*/) cpath=${cpath%/} ;;
			*) break ;;
			esac
		done
		case /$cpath/ in
		// | //* | */../* | */./*) die "путь копирования должен быть относительным путём внутри проекта: $cpath" ;;
		*"$tab"* | *"$nl"*) die "табуляция и перевод строки в пути копирования не поддерживаются" ;;
		esac
		copies=$copies$cpath$nl
	done

	list_tasks
	while IFS=$tab read -r ttask tbranch tpath; do
		[ "$ttask" = "$task" ] && die "задача $task уже идёт: ветка $tbranch, worktree $tpath"
	done <<EOF
$TASKS
EOF
	git show-ref --verify --quiet "refs/heads/$branch" && die "ветка $branch уже есть в репозитории"
	fetch
	git show-ref --verify --quiet "refs/remotes/origin/$branch" && die "ветка $branch уже есть на origin"
	while IFS= read -r cpath; do
		[ -n "$cpath" ] || continue
		if [ -e "$cpath" ] || [ -L "$cpath" ]; then
			git check-ignore -q -- "$cpath" ||
				die "git не игнорирует $cpath: копия могла бы попасть в коммит, поэтому worktree не создан"
		fi
	done <<EOF
$copies
EOF

	name=$(printf '%s' "$branch" | tr '/' '-')
	json=$(orca worktree create --name "$name" --setup skip --no-parent \
		--base-branch "origin/$base" --json 2>&1)
	path=$(printf '%s\n' "$json" | jq -r 'select(.ok == true) | .result.worktree.path // empty' 2>/dev/null)
	[ -n "$path" ] || die "Orca не создал worktree:$nl$json"
	obranch=$(git -C "$path" symbolic-ref --short -q HEAD) || die "в новом worktree $path нет ветки"
	git -C "$path" branch -m "$obranch" "$branch" ||
		die "не удалось переименовать ветку $obranch в $branch (worktree $path)"
	git config "branch.$branch.devparallel" "$task" || die "не удалось пометить ветку $branch"
	want=$(git rev-parse "origin/$base")
	if [ "$(git -C "$path" rev-parse HEAD)" != "$want" ]; then
		git -C "$path" reset --quiet --hard "$want" || die "не удалось поставить $path на origin/$base"
		printf 'Новый worktree переставлен на свежий origin/%s\n' "$base"
	fi

	while IFS= read -r cpath; do
		[ -n "$cpath" ] || continue
		if [ ! -e "$cpath" ]; then
			printf 'нет в главном worktree, не скопирован: %s\n' "$cpath"
		elif [ -e "$path/$cpath" ] || [ -L "$path/$cpath" ]; then
			printf 'уже есть в worktree, не перезаписан: %s\n' "$cpath"
		else
			mkdir -p "$(dirname "$path/$cpath")" && cp -RLp "$cpath" "$path/$cpath" ||
				die "не удалось скопировать $cpath в $path"
			printf 'скопирован: %s\n' "$cpath"
		fi
	done <<EOF
$copies
EOF
}

# delivery ЗАДАЧА ВЕТКА: просьба сдать задачу через pull request из этой ветки и следить
# за ним, пока его не сольют или не закроют.
delivery() {
	printf 'Сдай задачу через pull request по разделу «Сдача через pull request» скила dev: когда отчёт готов, закоммить изменения, запушь ветку %s и открой pull request в %s с отчётом в описании. Не сливай. Команда наблюдения за pull request: %s watch %s' \
		"$2" "$base" "$(shquote "$self")" "$1"
}

# launch КОМАНДА: выполнить команду в первом терминале worktree path, а если терминала
# нет — в новой вкладке. Набирается только запуск файла с командой, поэтому строка
# ввода короткая, какой бы длинной ни была команда.
launch() {
	lgit=$(git -C "$path" rev-parse --absolute-git-dir) || die "не найден каталог git worktree $path"
	printf '%s\n' "$1" >"$lgit/devparallel-run" || die "не удалось записать команду запуска в $lgit"
	typed="sh $(shquote "$lgit/devparallel-run")"
	handle=
	waited=0
	while :; do
		handle=$(orca terminal list --worktree "path:$path" --json 2>/dev/null |
			jq -r 'select(.ok == true) | .result.terminals[0].handle // empty' 2>/dev/null)
		[ -z "$handle" ] && [ "$waited" -lt "$terminal_wait" ] || break
		waited=$((waited + 1))
		sleep 1
	done
	if [ -n "$handle" ]; then
		out=$(orca terminal send --terminal "$handle" --text "$typed" --enter --json 2>&1)
	else
		out=$(orca terminal create --worktree "path:$path" --command "$typed" --json 2>&1)
	fi
	printf '%s\n' "$out" | jq -e '.ok == true' >/dev/null 2>&1 ||
		die "Claude не запущен в $path:$nl$out${nl}Worktree и ветка созданы; запусти в нём: $typed"
}

# new_session_id: номер новой сессии Claude — в sid. Берётся до создания worktree,
# чтобы без uuidgen worktree не появлялся.
new_session_id() {
	sid=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')
	[ -n "$sid" ] || die 'uuidgen не выдал номер для сессии Claude'
}

# run_session ПРОМПТ [ФЛАГ]...: запустить в терминале worktree path сессию Claude с номером
# sid и флагами перед ним. Обёртка пишет номер своего процесса и код выхода Claude в
# каталог git worktree (sgit), и по ним session_state узнаёт, идёт ли сессия.
run_session() {
	rprompt=$1
	shift
	sgit=$(git -C "$path" rev-parse --absolute-git-dir) || die "не найден каталог git worktree $path"
	printf '%s\n' "$sid" >"$sgit/devparallel-session" || die "не удалось записать номер сессии в $sgit"
	launch "echo \$\$ >$(shquote "$sgit/devparallel-pid"); claude ${*:+$* }--session-id $sid $(shquote "$rprompt"); echo \$? >$(shquote "$sgit/devparallel-exit")"
}

cmd_start() {
	[ $# -ge 2 ] || bad_call
	new_session_id
	prepare_worktree "$@"
	run_session "/dev:dev $task. $(delivery "$task" "$branch")"
	printf 'Задача %s: ветка %s, worktree %s, сессия Claude %s\n' "$task" "$branch" "$path" "$sid"
}

# Сессия настройки интерактивная и идёт в терминале Orca, как у start: claude -p
# выходит, как только ведущий завершает ход в ожидании фонового субагента, и
# обрывает работу субагента на полпути.
cmd_setup() {
	[ $# -ge 1 ] || bad_call
	new_session_id
	prepare_worktree setup "$@"
	prompt="/dev:dev Настрой проект для параллельной работы дирижёра dev-parallel. Готово, когда в ядре профиля проверок есть раздел «Параллельная работа», собранный по шагу «Опиши параллельную работу» слоя dev-profile, и ни одна опорная проверка не занимает общий ресурс машины; если занимает, исправь её так, чтобы каждый прогон брал свой ресурс. Ты в отдельном worktree, а главный worktree проекта — $main_wt: игнорируемые файлы смотри в нём. Ты работаешь без человека, по поручению дирижёра: согласовывать условие готовности не нужно, вопросы не задаются. $(delivery setup "$branch")"
	run_session "$prompt" --permission-mode auto
	waited=0
	while [ ! -s "$sgit/devparallel-pid" ]; do
		[ "$waited" -lt "$session_wait" ] ||
			die "команда в терминале worktree $path не началась за $session_wait с; worktree оставлен"
		waited=$((waited + 1))
		sleep 1
	done
	printf 'Сессия настройки %s идёт в терминале worktree %s\n' "$sid" "$path"
}

cmd_setup_wait() {
	[ $# -eq 0 ] || bad_call
	find_task setup
	while :; do
		# Состояние сессии берётся до запроса о PR: если сессия открыла PR и вышла
		# между двумя проверками, этот запрос PR уже увидит.
		session_state "$TASK_PATH"
		if pr_of "$TASK_BRANCH"; then
			if [ "$PR_STATE" = OPEN ]; then
				printf 'Pull request #%s открыт: %s\nОтчёт сессии настройки:\n%s\n' \
					"$PR_NUM" "$PR_URL" "$(pr_body "$PR_NUM")"
				return 0
			fi
			answered=1
		else
			answered=0
		fi
		case $SESSION_STATE in
		running) ;;
		none) die "сессия настройки в worktree $TASK_PATH не началась" ;;
		*)
			[ $answered -eq 1 ] || die 'GitHub не ответил на запрос о PR'
			break
			;;
		esac
		sleep "$poll"
	done
	session_end "$TASK_PATH"
	printf 'Сессия настройки закончилась без pull request: %s. Настройка не сдана, worktree %s оставлен.\nПродолжить сессию: %s\n' \
		"$SESSION_END" "$TASK_PATH" "$SESSION_RESUME" >&2
	exit 6
}

cmd_status() {
	[ $# -eq 0 ] || bad_call
	list_tasks
	if [ -z "$TASKS" ]; then
		printf 'Задач в worktree нет.\n'
		return 0
	fi
	git fetch --quiet origin || printf 'git fetch не удался: сведения об origin могут быть устаревшими\n'
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/dev-parallel.XXXXXX") || die 'не удалось создать временный каталог'
	trap 'rm -rf "$tmp"' EXIT
	ids=
	while IFS=$tab read -r stask sbranch spath; do
		ids=$ids$stask$nl
		printf 'Задача %s: ветка %s, worktree %s\n' "$stask" "$sbranch" "$spath"
		changes=$(dirty "$spath" | wc -l | tr -d ' ')
		if in_merge "$spath"; then
			printf '  идёт слияние, не завершено\n'
		elif [ "$changes" -gt 0 ]; then
			printf '  файлов с незакоммиченными изменениями: %s\n' "$changes"
		else
			printf '  незакоммиченных изменений нет\n'
		fi
		session_state "$spath"
		if [ -n "$SESSION_ID" ]; then
			case $SESSION_STATE in
			none) printf '  сессия Claude не началась\n' ;;
			running) printf '  сессия Claude идёт\n' ;;
			exited) printf '  сессия Claude закончилась, код %s\n' "$SESSION_CODE" ;;
			gone) printf '  сессия Claude оборвалась: терминал закрыт\n' ;;
			esac
			if [ "$SESSION_STATE" = exited ] || [ "$SESSION_STATE" = gone ]; then
				session_end "$spath"
				printf '  продолжить сессию: %s\n' "$SESSION_RESUME"
			fi
		fi
		if git show-ref --verify --quiet "refs/remotes/origin/$sbranch"; then
			ahead=$(git rev-list --count "origin/$sbranch..$sbranch")
			remote_only=$(git rev-list --count "$sbranch..origin/$sbranch")
			if [ "$ahead" -eq 0 ] && [ "$remote_only" -eq 0 ]; then
				printf '  ветка запушена\n'
			else
				printf '  не запушено коммитов: %s; на origin коммитов, которых нет локально: %s\n' \
					"$ahead" "$remote_only"
			fi
		else
			printf '  ветки на origin нет\n'
		fi
		printf '  отстаёт от origin/%s на коммитов: %s\n' "$base" \
			"$(git rev-list --count "$sbranch..origin/$base")"
		if ! pr_of "$sbranch"; then
			printf '  PR: GitHub не ответил\n'
		elif [ -z "$PR_NUM" ]; then
			printf '  PR нет\n'
		else
			if [ "$PR_STATE" = OPEN ]; then
				ci_state "$PR_NUM"
				case $CI_STATE in
				green) ci='зелёный' ;;
				red) ci="красный: $(printf '%s' "$CI_FAILED" | tr '\n' ';')" ;;
				pending) ci='идёт' ;;
				none) ci='проверок нет' ;;
				esac
				printf '  PR #%s %s, CI %s\n' "$PR_NUM" "$PR_URL" "$ci"
			else
				printf '  PR #%s %s, состояние %s\n' "$PR_NUM" "$PR_URL" "$PR_STATE"
			fi
		fi
		{
			git diff --name-only "origin/$base...$sbranch"
			git -C "$spath" diff --name-only HEAD
			git -C "$spath" ls-files --others --exclude-standard
		} | LC_ALL=C sort -u >"$tmp/$stask"
	done <<EOF
$TASKS
EOF

	printf 'Общие изменённые файлы:\n'
	found=0
	rest=$ids
	for a in $ids; do
		rest=$(printf '%s' "$rest" | sed '1d')
		for b in $rest; do
			common=$(LC_ALL=C comm -12 "$tmp/$a" "$tmp/$b" | tr '\n' ' ')
			if [ -n "$common" ]; then
				printf '  %s и %s: %s\n' "$a" "$b" "$common"
				found=1
			fi
		done
	done
	[ $found -eq 1 ] || printf '  нет\n'
}

# watch держит сессия задачи, пока её PR открыт. Сбой ответа GitHub его не обрывает.
# Итог проверок смотрится, только когда головной коммит PR совпадает с веткой: пока
# push сессии не дошёл до PR или коммит sync ещё не запушен, красный итог прежнего
# коммита ничего не говорит о ветке.
cmd_watch() {
	[ $# -eq 1 ] || bad_call
	find_task "$1"
	while :; do
		if pr_of "$TASK_BRANCH" && [ -n "$PR_NUM" ]; then
			case $PR_STATE in
			MERGED)
				printf 'PR #%s слит: %s\n' "$PR_NUM" "$PR_URL"
				return 0
				;;
			CLOSED)
				printf 'PR #%s закрыт без слияния: %s\n' "$PR_NUM" "$PR_URL"
				return 0
				;;
			esac
			whead=$(pr_head "$PR_NUM")
			if [ -n "$whead" ] && [ "$whead" = "$(git rev-parse -q --verify "refs/heads/$TASK_BRANCH")" ]; then
				ci_state "$PR_NUM"
				if [ "$CI_STATE" = red ]; then
					printf 'CI красный на коммите %s, PR #%s %s. Упали:\n%s' \
						"$whead" "$PR_NUM" "$PR_URL" "$CI_FAILED"
					exit 4
				fi
			fi
		fi
		sleep "$watch_poll"
	done
}

cmd_sync() {
	[ $# -eq 2 ] && [ -n "$2" ] || bad_call
	find_task "$1"
	msg=$2
	in_merge "$TASK_PATH" &&
		die "в worktree задачи $1 уже идёт слияние: разреши его или отмени (git merge --abort)"
	changes=$(dirty "$TASK_PATH")
	[ -z "$changes" ] ||
		die "в worktree задачи $1 незакоммиченные изменения, значит, сессия задачи ещё работает:$nl$changes"
	pr_of "$TASK_BRANCH" || die 'GitHub не ответил на запрос о PR'
	[ "$PR_STATE" = OPEN ] || die "у ветки $TASK_BRANCH нет открытого PR: задача ещё не сдана"
	fetch
	pushed "$TASK_BRANCH" ||
		die "ветка $TASK_BRANCH расходится с origin: сначала сессия задачи должна запушить свою работу"
	if git merge-base --is-ancestor "origin/$base" "$TASK_BRANCH"; then
		printf 'Ветка %s уже содержит origin/%s, вливать нечего.\n' "$TASK_BRANCH" "$base"
		return 0
	fi
	if out=$(git -C "$TASK_PATH" merge --no-ff --no-edit -m "$msg" "origin/$base" 2>&1); then
		printf 'origin/%s влит в %s без конфликтов, коммит %s\n' \
			"$base" "$TASK_BRANCH" "$(git rev-parse --short "$TASK_BRANCH")"
		return 0
	fi
	conflicts=$(git -C "$TASK_PATH" diff --name-only --diff-filter=U)
	if [ -n "$conflicts" ]; then
		printf 'Конфликт при вливании origin/%s в %s. Слияние оставлено незавершённым в %s.\nФайлы с конфликтом:\n%s\n' \
			"$base" "$TASK_BRANCH" "$TASK_PATH" "$conflicts"
		exit 3
	fi
	in_merge "$TASK_PATH" && git -C "$TASK_PATH" merge --abort
	die "слияние не удалось:$nl$out"
}

cmd_land() {
	[ $# -ge 1 ] || bad_call
	task=$1
	shift
	without_ci=0
	if [ $# -gt 0 ]; then
		[ "$1" = --without-ci ] && [ $# -eq 1 ] || bad_call
		without_ci=1
	fi
	find_task "$task"
	in_merge "$TASK_PATH" && die "слияние в worktree задачи $task не завершено"
	changes=$(dirty "$TASK_PATH")
	[ -z "$changes" ] || die "в worktree задачи $task незакоммиченные изменения:$nl$changes"
	fetch
	git merge-base --is-ancestor "origin/$base" "$TASK_BRANCH" ||
		die "ветка $TASK_BRANCH не содержит свежий origin/$base: сначала sync"
	pr_of "$TASK_BRANCH" || die 'GitHub не ответил на запрос о PR'
	[ "$PR_STATE" = OPEN ] || die "у ветки $TASK_BRANCH нет открытого PR"
	sha=$(git rev-parse "$TASK_BRANCH")
	if ! pushed "$TASK_BRANCH"; then
		out=$(git push --quiet origin "$TASK_BRANCH" 2>&1) ||
			die "push ветки $TASK_BRANCH отклонён:$nl$out"
		printf 'Ветка %s запушена\n' "$TASK_BRANCH"
	fi
	wait_head "$PR_NUM" "$sha"
	[ $without_ci -eq 1 ] || wait_green "$PR_NUM" "$sha"
	out=$(gh pr merge "$PR_NUM" --merge --match-head-commit "$sha" 2>&1) ||
		die "GitHub не слил PR #$PR_NUM:$nl$out"
	mstart=$(date +%s)
	while [ "$(pr_state "$PR_NUM")" != MERGED ]; do
		[ "$(elapsed_since "$mstart")" -lt 60 ] ||
			die "gh сообщил о слиянии, но PR #$PR_NUM за минуту не стал MERGED"
		sleep "$poll"
	done
	printf 'PR #%s слит: %s, коммит ветки %s\n' "$PR_NUM" "$PR_URL" "$sha"
}

# wait: дирижёр ждёт задачу, красный CI которой чинит её сессия. Сессия смотрится до
# запроса о PR: если она запушила исправление и вышла между двумя проверками, этот
# запрос уже увидит коммит. После конца сессии идущий CI ещё дожидаются: исправление
# могли запушить перед выходом.
cmd_wait() {
	[ $# -eq 1 ] || bad_call
	find_task "$1"
	ended=
	while :; do
		session_state "$TASK_PATH"
		CI_STATE=
		if pr_of "$TASK_BRANCH"; then
			[ -n "$PR_NUM" ] || die "у ветки $TASK_BRANCH нет PR"
			[ "$PR_STATE" = OPEN ] || die "PR #$PR_NUM $PR_URL в состоянии $PR_STATE: ждать нечего"
			whead=$(pr_head "$PR_NUM")
			ci_state "$PR_NUM"
			if [ "$CI_STATE" = green ] && [ -n "$whead" ]; then
				printf 'CI зелёный на коммите %s, PR #%s %s\n' "$whead" "$PR_NUM" "$PR_URL"
				return 0
			fi
		fi
		if [ -n "$SESSION_ID" ] && [ "$SESSION_STATE" != running ]; then
			case $CI_STATE in
			red) break ;;
			none)
				[ -n "$ended" ] || ended=$(date +%s)
				[ "$(elapsed_since "$ended")" -lt "$grace" ] || break
				;;
			esac
		fi
		sleep "$poll"
	done
	session_end "$TASK_PATH"
	printf 'Сессия задачи %s закончилась, а CI на PR #%s не зелёный: %s. Worktree %s оставлен.\n' \
		"$1" "$PR_NUM" "$SESSION_END" "$TASK_PATH" >&2
	[ -z "$CI_FAILED" ] || printf 'Упали:\n%s' "$CI_FAILED" >&2
	printf 'Продолжить сессию: %s\n' "$SESSION_RESUME" >&2
	exit 6
}

cmd_remove() {
	[ $# -ge 1 ] || bad_call
	task=$1
	shift
	cancel=0
	if [ $# -gt 0 ]; then
		[ "$1" = --cancel ] && [ $# -eq 1 ] || bad_call
		cancel=1
	fi
	find_task "$task"
	in_merge "$TASK_PATH" && die "в worktree задачи $task идёт слияние: разреши или отмени его"
	changes=$(dirty "$TASK_PATH")
	[ -z "$changes" ] ||
		die "в worktree задачи $task незакоммиченные изменения, удаление их бы уничтожило:$nl$changes"
	fetch
	pr_of "$TASK_BRANCH" || die 'GitHub не ответил на запрос о PR'
	sha=$(git rev-parse "$TASK_BRANCH")
	if [ $cancel -eq 0 ]; then
		[ "$PR_STATE" = MERGED ] ||
			die "PR ветки $TASK_BRANCH не слит (${PR_STATE:-PR нет}); отменить задачу — remove --cancel"
		git merge-base --is-ancestor "$sha" "origin/$base" ||
			die "в ветке $TASK_BRANCH есть коммиты, которых нет в origin/$base"
	elif [ "$PR_STATE" = OPEN ]; then
		out=$(gh pr close "$PR_NUM" 2>&1) || die "не удалось закрыть PR #$PR_NUM:$nl$out"
		printf 'PR #%s закрыт\n' "$PR_NUM"
	fi

	out=$(orca worktree rm --worktree "path:$TASK_PATH" --json 2>&1)
	printf '%s\n' "$out" | jq -e '.ok == true' >/dev/null 2>&1 ||
		die "Orca не удалил worktree $TASK_PATH:$nl$out"
	rstart=$(date +%s)
	while [ -e "$TASK_PATH" ]; do
		[ "$(elapsed_since "$rstart")" -lt 30 ] || die "Orca за 30 с не удалил каталог $TASK_PATH"
		sleep 1
	done
	git worktree prune

	if [ $cancel -eq 1 ]; then
		git show-ref --verify --quiet "refs/heads/$TASK_BRANCH" ||
			git branch "$TASK_BRANCH" "$sha" || die "не удалось вернуть ветку $TASK_BRANCH на $sha"
		git config --unset "branch.$TASK_BRANCH.devparallel" 2>/dev/null
		printf 'Задача %s отменена: worktree удалён, ветка %s оставлена (коммит %s).\n' \
			"$task" "$TASK_BRANCH" "$sha"
		return 0
	fi
	if git show-ref --verify --quiet "refs/remotes/origin/$TASK_BRANCH"; then
		out=$(git push --quiet origin --delete "$TASK_BRANCH" 2>&1) ||
			die "worktree удалён, но ветку $TASK_BRANCH на origin удалить не удалось:$nl$out"
	fi
	if git show-ref --verify --quiet "refs/heads/$TASK_BRANCH"; then
		git branch -D "$TASK_BRANCH" >/dev/null || die "не удалось удалить слитую ветку $TASK_BRANCH"
	fi
	printf 'Задача %s убрана: worktree удалён, ветка %s удалена локально и на origin.\n' \
		"$task" "$TASK_BRANCH"
}

case ${1:-} in
help | -h | --help)
	usage
	exit 0
	;;
home | start | setup | setup-wait | status | watch | sync | land | wait | remove) ;;
*) bad_call ;;
esac

need git
setup_repo
command=$1
shift
case $command in
home) cmd_home "$@" ;;
start)
	need jq orca
	cmd_start "$@"
	;;
setup)
	need jq orca claude
	cmd_setup "$@"
	;;
setup-wait)
	need gh
	cmd_setup_wait "$@"
	;;
status)
	need gh
	cmd_status "$@"
	;;
watch)
	need gh
	cmd_watch "$@"
	;;
sync)
	need gh
	cmd_sync "$@"
	;;
land)
	need gh
	cmd_land "$@"
	;;
wait)
	need gh
	cmd_wait "$@"
	;;
remove)
	need gh jq orca
	cmd_remove "$@"
	;;
esac
