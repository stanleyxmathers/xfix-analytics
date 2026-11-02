#!/usr/bin/env bash
# Кладёт в буфер обмена шаги скрипта FileMaker «XFIX выгрузка очереди» (macOS).
# Дальше: FileMaker → Скрипты → Рабочее пространство скриптов → новый скрипт → Cmd+V.
# Настройка шага «Экспортировать записи» после вставки — FileMaker_выгрузка_очереди.md.
set -euo pipefail
XML="$(mktemp -t xfix_export).xml"
cat > "$XML" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<fmxmlsnippet type="FMObjectList">
<Step enable="True" id="89" name="# (comment)"><Text>XFIX: выгрузка техники в работе для «Планирования». Запускать с макета карточек сервиса (таблица Service).</Text></Step>
<Step enable="True" id="86" name="Set Error Capture"><Set state="True"/></Step>
<Step enable="True" id="141" name="Set Variable"><Value><Calculation><![CDATA[Get ( LayoutTableName )]]></Calculation></Value><Repetition><Calculation><![CDATA[1]]></Calculation></Repetition><Name>$to</Name></Step>
<Step enable="True" id="68" name="If"><Calculation><![CDATA[Let ( t = FieldType ( Get ( FileName ) ; $to & "::Дата время завершения этапа в текущем статусе" ) ; IsEmpty ( t ) or t = "?" )]]></Calculation></Step>
<Step enable="True" id="87" name="Show Custom Dialog"><Title><Calculation><![CDATA["XFIX выгрузка"]]></Calculation></Title><Message><Calculation><![CDATA["Откройте макет карточек сервиса (таблица Service) и запустите скрипт ещё раз. Сейчас макет: " & Get ( LayoutName )]]></Calculation></Message><Buttons><Button CommitState="False"><Calculation><![CDATA["OK"]]></Calculation></Button><Button CommitState="False"/><Button CommitState="False"/></Buttons></Step>
<Step enable="True" id="103" name="Exit Script"/>
<Step enable="True" id="70" name="End If"/>
<Step enable="True" id="89" name="# (comment)"><Text>Статусы техники в работе — точные названия из базы</Text></Step>
<Step enable="True" id="141" name="Set Variable"><Value><Calculation><![CDATA[List ( "Доставка" ; "Ожидаем получения" ; "В работе" ; "Диагностика" ; "На согласование" ; "На осмотр внутри" ; "К заказу" ; "Определение стратегии обслуживания" ; "На отправку" ; "Проверка после ЗАСЦ" ; "Проверка" ; "К выдаче" )]]></Calculation></Value><Repetition><Calculation><![CDATA[1]]></Calculation></Repetition><Name>$statuses</Name></Step>
<Step enable="True" id="22" name="Enter Find Mode"><Pause state="False"/><Restore state="False"/></Step>
<Step enable="True" id="141" name="Set Variable"><Value><Calculation><![CDATA[1]]></Calculation></Value><Repetition><Calculation><![CDATA[1]]></Calculation></Repetition><Name>$i</Name></Step>
<Step enable="True" id="71" name="Loop"/>
<Step enable="True" id="147" name="Set Field By Name"><Result><Calculation><![CDATA["==" & GetValue ( $statuses ; $i )]]></Calculation></Result><TargetName><Calculation><![CDATA[$to & "::Статус"]]></Calculation></TargetName></Step>
<Step enable="True" id="141" name="Set Variable"><Value><Calculation><![CDATA[$i + 1]]></Calculation></Value><Repetition><Calculation><![CDATA[1]]></Calculation></Repetition><Name>$i</Name></Step>
<Step enable="True" id="72" name="Exit Loop If"><Calculation><![CDATA[$i > ValueCount ( $statuses )]]></Calculation></Step>
<Step enable="True" id="7" name="New Record/Request"/>
<Step enable="True" id="73" name="End Loop"/>
<Step enable="True" id="28" name="Perform Find"><Restore state="False"/></Step>
<Step enable="True" id="68" name="If"><Calculation><![CDATA[Get ( FoundCount ) = 0]]></Calculation></Step>
<Step enable="True" id="87" name="Show Custom Dialog"><Title><Calculation><![CDATA["XFIX выгрузка"]]></Calculation></Title><Message><Calculation><![CDATA["Не найдено ни одной карточки в статусах:¶" & $statuses]]></Calculation></Message><Buttons><Button CommitState="False"><Calculation><![CDATA["OK"]]></Calculation></Button><Button CommitState="False"/><Button CommitState="False"/></Buttons></Step>
<Step enable="True" id="103" name="Exit Script"/>
<Step enable="True" id="70" name="End If"/>
<Step enable="True" id="141" name="Set Variable"><Value><Calculation><![CDATA[Get ( CurrentTimestamp )]]></Calculation></Value><Repetition><Calculation><![CDATA[1]]></Calculation></Repetition><Name>$ts</Name></Step>
<Step enable="True" id="141" name="Set Variable"><Value><Calculation><![CDATA["xfix_queue_" & Year ( $ts ) & Right ( "0" & Month ( $ts ) ; 2 ) & Right ( "0" & Day ( $ts ) ; 2 ) & "_" & Right ( "0" & Hour ( $ts ) ; 2 ) & Right ( "0" & Minute ( $ts ) ; 2 ) & ".xlsx"]]></Calculation></Value><Repetition><Calculation><![CDATA[1]]></Calculation></Repetition><Name>$name</Name></Step>
<Step enable="True" id="141" name="Set Variable"><Value><Calculation><![CDATA["file:" & Get ( DesktopPath ) & $name]]></Calculation></Value><Repetition><Calculation><![CDATA[1]]></Calculation></Repetition><Name>$path</Name></Step>
<Step enable="True" id="89" name="# (comment)"><Text>Один раз настроить: файл $path, Excel, «имена полей в первой строке», порядок экспорта — 21 поле</Text></Step>
<Step enable="True" id="36" name="Export Records"><NoInteract state="True"/><CreateDirectories state="False"/><Restore state="False"/><UniversalPathList>$path</UniversalPathList></Step>
<Step enable="True" id="68" name="If"><Calculation><![CDATA[Get ( LastError ) ≠ 0]]></Calculation></Step>
<Step enable="True" id="87" name="Show Custom Dialog"><Title><Calculation><![CDATA["XFIX выгрузка"]]></Calculation></Title><Message><Calculation><![CDATA["Экспорт не удался, ошибка " & Get ( LastError ) & ". Проверьте настройки шага «Экспортировать записи»."]]></Calculation></Message><Buttons><Button CommitState="False"><Calculation><![CDATA["OK"]]></Calculation></Button><Button CommitState="False"/><Button CommitState="False"/></Buttons></Step>
<Step enable="True" id="69" name="Else"/>
<Step enable="True" id="87" name="Show Custom Dialog"><Title><Calculation><![CDATA["XFIX выгрузка"]]></Calculation></Title><Message><Calculation><![CDATA["Сохранено на рабочий стол: " & $name & "¶Устройств: " & Get ( FoundCount )]]></Calculation></Message><Buttons><Button CommitState="False"><Calculation><![CDATA["OK"]]></Calculation></Button><Button CommitState="False"/><Button CommitState="False"/></Buttons></Step>
<Step enable="True" id="70" name="End If"/>
</fmxmlsnippet>
EOF
osascript -e "set the clipboard to «data XMSS$(xxd -p "$XML" | tr -d '\n')»"
rm -f "$XML"
echo "Шаги скрипта в буфере обмена — вставьте их в пустой скрипт FileMaker (Cmd+V)"
