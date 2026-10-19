#!/bin/sh
# Помощник безопасной порчи: сохранить файлы, испортить, вернуть и сверить.
#
#   safe-mutation.sh save ФАЙЛ...   сохранить копии до порчи
#   safe-mutation.sh status         показать, что сохранено и что изменилось
#   safe-mutation.sh restore        вернуть файлы, сверить байт в байт, снять состояние
#   safe-mutation.sh help           эта справка
#
# Файл исполняемый: зови его по пути, без sh. Путь в переменной работает и в zsh,
# а команда «sh путь» в переменной там не разбивается на слова и не выполняется.
#
# Корень проекта: корень git-репозитория, а без git — текущий каталог.
# Файлы указываются относительно текущего каталога или абсолютными путями;
# они должны лежать внутри корня. Каталоги, символические ссылки и пути
# внутри .git не принимаются.
#
# Файл, которого нет при сохранении, запоминается как «отсутствовал»:
# restore удалит его, а вместе с ним каталоги, которых не было до опыта
# и которые стали пустыми.
#
# Копии лежат во временном каталоге вне корня, отдельном для каждого корня
# (каталог $TMPDIR, а без него /tmp). Пока сохранённое не возвращено, save
# отказывает для любых файлов, и копии остаются нетронутыми. При любой
# неудаче restore выходит с ненулевым кодом, а копии и состояние остаются.
# Выход: 0 — успех, 1 — отказ или сбой, 2 — неверный вызов.

set -u

tab=$(printf '\t')
nl=$(printf '\n.')
nl=${nl%.}

die() {
	printf 'safe-mutation: %s\n' "$*" >&2
	exit 1
}

usage() {
	sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//; /^$/d'
}

cwd=$(pwd -P) || die 'не удалось определить текущий каталог'
if root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$root" ]; then
	root=$(cd "$root" && pwd -P) || die 'не удалось определить корень проекта'
else
	root=$cwd
fi

tmpbase=${TMPDIR:-/tmp}
tmpbase=$(cd "$tmpbase" 2>/dev/null && pwd -P) ||
	die "временный каталог недоступен: ${TMPDIR:-/tmp}"
case $tmpbase/ in
"$root"/*) die "временный каталог $tmpbase лежит внутри корня проекта $root; задай TMPDIR вне проекта" ;;
esac

rootname=$(printf '%s' "${root##*/}" | tr -c 'A-Za-z0-9._-' '_')
rootsum=$(printf '%s' "$root" | cksum | cut -d' ' -f1)
state=$tmpbase/safe-mutation-$rootname-$rootsum

# norm ПУТЬ: абсолютный путь без . и .. записывается в NORM.
norm() {
	case $1 in
	/*) np=$1 ;;
	*) np=$cwd/$1 ;;
	esac
	nout=
	nifs=$IFS
	IFS=/
	set -f
	for nseg in $np; do
		case $nseg in
		'' | .) ;;
		..) nout=${nout%/*} ;;
		*) nout=$nout/$nseg ;;
		esac
	done
	set +f
	IFS=$nifs
	NORM=${nout:-/}
}

# Откат неудачного save: состояние создано этим же вызовом, поэтому его можно снять.
save_fail() {
	rm -rf "$state"
	die "$* Ничего не сохранено."
}

cmd_save() {
	[ $# -gt 0 ] || {
		usage >&2
		exit 2
	}
	if [ -e "$state" ]; then
		prev=$(cat "$state/root" 2>/dev/null)
		die "уже есть сохранённое (корень ${prev:-неизвестен}, копии в $state). Повторное сохранение отказано, копии не тронуты. Сначала верни: restore."
	fi
	mkdir "$state" 2>/dev/null || die "не удалось создать каталог копий $state"
	chmod 700 "$state"
	mkdir "$state/files" || save_fail 'не удалось создать каталог копий.'
	printf '%s\n' "$root" >"$state/root" || save_fail 'не удалось записать состояние.'
	: >"$state/manifest" || save_fail 'не удалось записать состояние.'

	n=0
	saved=0
	for arg in "$@"; do
		norm "$arg"
		abs=$NORM
		case $abs in
		"$root"/*) ;;
		*) save_fail "путь вне корня проекта $root: $arg." ;;
		esac
		rel=${abs#"$root"/}
		case $rel in
		.git | .git/*) save_fail "путь внутри .git не принимается: $arg." ;;
		*"$tab"* | *"$nl"*) save_fail "табуляция и перевод строки в пути не поддерживаются: $arg." ;;
		esac
		dup=0
		while IFS=$tab read -r _k _n _t prel; do
			[ "$prel" = "$rel" ] && dup=1
		done <"$state/manifest"
		[ $dup -eq 1 ] && continue
		[ -L "$abs" ] && save_fail "символическая ссылка не принимается: $arg."
		[ -d "$abs" ] && save_fail "каталог не принимается, укажи файлы: $arg."

		# Ближайший существующий каталог и самый верхний отсутствующий предок.
		d=${abs%/*}
		top=
		while [ -n "$d" ] && [ "$d" != "$root" ] && [ ! -d "$d" ]; do
			top=$d
			d=${d%/*}
		done
		real=$(cd "$d" 2>/dev/null && pwd -P) || save_fail "каталог недоступен: $arg."
		case $real in
		"$root" | "$root"/*) ;;
		*) save_fail "путь выходит за корень через ссылку на каталог: $arg." ;;
		esac

		n=$((n + 1))
		if [ -f "$abs" ]; then
			cp -p "$abs" "$state/files/$n" && cmp -s "$abs" "$state/files/$n" ||
				save_fail "не удалось сохранить: $arg."
			printf 'S\t%s\t.\t%s\n' "$n" "$rel" >>"$state/manifest"
			printf 'сохранён: %s\n' "$rel"
		elif [ -e "$abs" ]; then
			save_fail "не обычный файл: $arg."
		else
			if [ -n "$top" ]; then
				toprel=${top#"$root"/}
			else
				toprel=.
			fi
			printf 'A\t%s\t%s\t%s\n' "$n" "$toprel" "$rel" >>"$state/manifest"
			printf 'отсутствует (restore удалит): %s\n' "$rel"
		fi
		saved=$((saved + 1))
	done
	printf 'Сохранено записей: %s. Копии: %s\n' "$saved" "$state"
}

check_state() {
	[ -d "$state" ] || die "нечего возвращать: для $root ничего не сохранено."
	[ "$(cat "$state/root" 2>/dev/null)" = "$root" ] ||
		die "состояние $state принадлежит другому корню; корень сейчас $root."
}

cmd_status() {
	if [ ! -d "$state" ]; then
		printf 'Ничего не сохранено для %s\n' "$root"
		return 0
	fi
	check_state
	printf 'Копии: %s\n' "$state"
	while IFS=$tab read -r kind n top rel; do
		[ -n "$kind" ] || continue
		target=$root/$rel
		if [ "$kind" = S ]; then
			if [ -f "$target" ] && cmp -s "$state/files/$n" "$target"; then
				printf 'сохранён, не менялся: %s\n' "$rel"
			else
				printf 'сохранён, сейчас отличается или удалён: %s\n' "$rel"
			fi
		elif [ -e "$target" ] || [ -L "$target" ]; then
			printf 'отсутствовал, сейчас есть: %s\n' "$rel"
		else
			printf 'отсутствовал, и сейчас нет: %s\n' "$rel"
		fi
	done <"$state/manifest"
}

cmd_restore() {
	check_state
	bad=0
	count=0
	while IFS=$tab read -r kind n top rel; do
		[ -n "$kind" ] || continue
		count=$((count + 1))
		target=$root/$rel
		if [ -L "$target" ]; then
			rm -f "$target"
		fi
		if [ -d "$target" ]; then
			printf 'НЕ ВОЗВРАЩЁН (на месте файла каталог): %s\n' "$rel"
			bad=1
			continue
		fi
		if [ "$kind" = S ]; then
			rm -f "$target" 2>/dev/null
			if mkdir -p "${target%/*}" 2>/dev/null &&
				cp -p "$state/files/$n" "$target" 2>/dev/null &&
				cmp -s "$state/files/$n" "$target"; then
				printf 'возвращён, сверен: %s\n' "$rel"
			else
				printf 'НЕ СОШЛОСЬ с копией: %s\n' "$rel"
				bad=1
			fi
		else
			rm -f "$target" 2>/dev/null
			if [ -e "$target" ] || [ -L "$target" ]; then
				printf 'НЕ УДАЛЁН: %s\n' "$rel"
				bad=1
				continue
			fi
			if [ "$top" != . ]; then
				dir=${target%/*}
				while [ "$dir" != "$root" ]; do
					rmdir "$dir" 2>/dev/null || break
					[ "$dir" = "$root/$top" ] && break
					dir=${dir%/*}
				done
			fi
			printf 'удалён (создан опытом): %s\n' "$rel"
		fi
	done <"$state/manifest"

	if [ $bad -ne 0 ]; then
		printf 'Сверка не сошлась. Состояние и копии оставлены: %s\n' "$state" >&2
		exit 1
	fi
	rm -rf "$state" || die "всё возвращено и сверено, но состояние не снялось: $state"
	printf 'Возвращено и сверено записей: %s. Состояние снято.\n' "$count"
}

case ${1:-} in
save)
	shift
	cmd_save "$@"
	;;
status) cmd_status ;;
restore) cmd_restore ;;
help | -h | --help) usage ;;
*)
	usage >&2
	exit 2
	;;
esac
