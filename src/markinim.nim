import std/[asyncdispatch, logging, options, os, times, strutils, strformat, tables, random, sets, parsecfg, sequtils, streams]
import telebot, norm / [model, sqlite], nimkov / generator
import ./database

var L = newConsoleLogger(fmtStr="$levelname | [$time] ")
addHandler(L)

var
  conn: DbConn
  botUsername: string
  admins: HashSet[int64]
  markovs: Table[int64, (MarkovGenerator, int64)]
  adminsCache: Table[(int64, int64), (int64, bool)] # (chatId, userId): (unixtime, isAdmin) cache
  antiFlood: Table[int64, seq[int64]]

let uptime = epochTime()

const
  MARKOV_DB = "markov.db"

  ANTIFLOOD_SECONDS = 15
  ANTIFLOOD_RATE = 5

  MARKOV_SAMPLES_CACHE_TIMEOUT = 60 * 30 # 30 minutes
  GROUP_ADMINS_CACHE_TIMEOUT = 60 * 5 # result is valid for five minutes

template get(self: Table[int64, (MarkovGenerator, int64)], chatId: int64): MarkovGenerator =
  self[chatId][0]

template unixTime: int64 =
  getTime().toUnix

proc isFlood(chatId: int64, rate: int = ANTIFLOOD_RATE, seconds: int = ANTIFLOOD_SECONDS): bool =
  let time = unixTime()
  if chatId notin antiFlood:
    antiflood[chatId] = @[time]
  else:
    antiFlood[chatId].add(time)

  antiflood[chatId] = antiflood[chatId].filterIt(time - it < seconds)
  return len(antiflood[chatId]) > rate

proc cleanerWorker {.async.} =
  while true:
    let
      time = unixTime()
      antiFloodKeys = antiFlood.keys.toSeq()

    for chatId in antiFloodKeys:
      let messages = antiflood[chatId].filterIt(time - it < ANTIFLOOD_SECONDS)
      if len(messages) != 0:
        antiFlood[chatId] = antiflood[chatId].filterIt(time - it < ANTIFLOOD_SECONDS)
      else:
        antiflood.del(chatId)
    
    let adminsCacheKeys = adminsCache.keys.toSeq()
    for record in adminsCacheKeys:
      let (timestamp, isAdmin) = adminsCache[record]
      if time - timestamp > GROUP_ADMINS_CACHE_TIMEOUT:
        adminsCache.del(record)
    
    let markovsKeys = markovs.keys.toSeq()
    for record in markovsKeys:
      let (_, timestamp) = markovs[record]
      if time - timestamp > MARKOV_SAMPLES_CACHE_TIMEOUT:
        markovs.del(record)

    await sleepAsync(30)

proc isAdminInGroup(bot: Telebot, chatId: int64, userId: int64): Future[bool] {.async.} =
  let time = unixTime()
  if (chatId, userId) in adminsCache:
    let (_, isAdmin) = adminsCache[(chatId, userId)]
    return isAdmin

  try:
    let member = await bot.getChatMember(chatId = $chatId, userId = userId.int)
    result = member.status == "creator" or member.status == "administrator"
  except Exception:
    result = false

  adminsCache[(chatId, userId)] = (time, result)


type KeyboardInterrupt = ref object of CatchableError
proc handler() {.noconv.} =
  raise KeyboardInterrupt(msg: "Keyboard Interrupt")
setControlCHook(handler)


proc handleCommand(bot: Telebot, update: Update, command: string, args: seq[string]) {.async.} =
  let
    message = update.message.get
    senderId = message.fromUser.get().id

  case command:
  of "start":
    const startMessage = "Hello, I learn from your messages and try to formulate my own sentences. Add me in a chat or send /enable to try me out here ᗜᴗᗜ"
    if message.chat.id != senderId: # /start only works in PMs
      if len(args) > 0 and args[0] == "enable":
        discard await bot.sendMessage(message.chat.id, startMessage)
      return
    discard await bot.sendMessage(message.chat.id,
      startMessage,
      replyMarkup = newInlineKeyboardMarkup(@[InlineKeyboardButton(text: "Add me :D", url: some &"https://t.me/{botUsername}?startgroup=enable")])
    )
  of "help":
    discard
  of "admin", "unadmin", "remadmin":
    if len(args) < 1:
      return
    elif senderId notin admins:
      discard await bot.sendMessage(message.chat.id, &"You are not allowed to perform this command")
      return

    try:
      let userId = parseBiggestInt(args[0])
      discard conn.setAdmin(userId = userId, admin = (command == "admin"))
      
      if command == "admin":
        admins.incl(userId)
      else:
        admins.excl(userId)

      discard await bot.sendMessage(message.chat.id,
        if command == "admin": &"Successfully promoted [{userId}](tg://user?id={userId})"
        else: &"Successfully demoted [{userId}](tg://user?id={userId})",
        parseMode = "markdown")
    except Exception as error:
      discard await bot.sendMessage(message.chat.id, &"An error occurred: <code>{$typeof(error)}: {getCurrentExceptionMsg()}</code>", parseMode = "html")
  of "count", "stats":
    if senderId notin admins:
      discard await bot.sendMessage(message.chat.id, &"You are not allowed to perform this command")
      return
    discard await bot.sendMessage(message.chat.id,
      &"*Users*: `{conn.getCount(database.User)}`\n*Chats*: `{conn.getCount(database.Chat)}`\n*Messages:* `{conn.getCount(database.Message)}`\n*Uptime*: `{toInt(epochTime() - uptime)}`s",
      parseMode = "markdown")
  of "enable", "disable":
    if message.chat.kind.endswith("group") and not await bot.isAdminInGroup(chatId = message.chat.id, userId = senderId):
      discard await bot.sendMessage(message.chat.id, "You are not allowed to perform this command")
      return

    discard conn.setEnabled(message.chat.id, enabled = (command == "enable"))

    discard await bot.sendMessage(message.chat.id,
      if command == "enable": "Successfully enabled learning in this chat"
      else: "Successfully disabled learning in this chat"
    )
  of "percentage":
    if message.chat.kind.endswith("group") and not await bot.isAdminInGroup(chatId = message.chat.id, userId = senderId):
      discard await bot.sendMessage(message.chat.id, "You are not allowed to perform this command")
      return
    
    var chat = conn.getOrInsert(database.Chat(chatId: message.chat.id))
    if len(args) == 0:
      discard await bot.sendMessage(message.chat.id,
        "This command needs an argument. Example: `/percentage 40` (default: `30`)\n" &
        &"Current percentage: `{chat.percentage}`%",
        parseMode = "markdown")
      return

    try:
      let percentage = parseInt(args[0].strip(chars = Whitespace + {'%'}))

      if percentage notin 1 .. 100:
        discard await bot.sendMessage(message.chat.id, "Percentage must be a number between 1 and 100")
        return

      chat.percentage = percentage
      conn.update(chat)

      discard await bot.sendMessage(message.chat.id,
        &"Percentage has been successfully updated to `{percentage}`%",
        parseMode = "markdown")
    except ValueError:
      discard await bot.sendMessage(message.chat.id, "The value you inserted is not a number")
  of "markov":
    let enabled = conn.getOrInsert(database.Chat(chatId: message.chat.id)).enabled
    if not enabled:
      discard bot.sendMessage(message.chat.id, "Learning is not enabled in this chat. Enable it with /enable (for groups: admins only)")
      return
    
    if not markovs.hasKey(message.chat.id):
      markovs[message.chat.id] = (newMarkov(@[]), unixTime())
      for dbMessage in conn.getLatestMessages(chatId = message.chat.id):
        if dbMessage.text != "":
          markovs.get(message.chat.id).addSample(dbMessage.text)

    if len(markovs.get(message.chat.id).getSamples()) == 0:
      discard await bot.sendMessage(message.chat.id, "Not enough data to generate a sentence")
      return

    let generated = markovs.get(message.chat.id).generate()
    if generated.isSome:
      discard await bot.sendMessage(message.chat.id, generated.get())
    else:
      discard await bot.sendMessage(message.chat.id, "Not enough data to generate a sentence")
  of "export":
    if senderId notin admins:
      # discard await bot.sendMessage(message.chat.id, &"You are not allowed to perform this command")
      return
    let tmp = getTempDir()
    copyFileToDir(MARKOV_DB, tmp)
    discard await bot.sendDocument(senderId, "file://" & (tmp / MARKOV_DB))
    discard tryRemoveFile(tmp / MARKOV_DB)
  of "settings":
    discard
  of "distort":
    discard
  of "hazmat":
    discard
  of "delete":
    var deleting {.global.}: HashSet[int64]

    if message.chat.kind.endswith("group") and not await bot.isAdminInGroup(chatId = message.chat.id, userId = senderId):
      discard await bot.sendMessage(message.chat.id, "You are not allowed to perform this command")
      return
    elif message.chat.id in deleting:
      discard await bot.sendMessage(message.chat.id, "I am already deleting the messages from my database. Please hold on")
    elif len(args) > 0 and args[0].toLower() == "confirm":
      deleting.incl(message.chat.id)
      defer: deleting.excl(message.chat.id)
      try:
        let sentMessage = await bot.sendMessage(message.chat.id, "I am deleting data for this chat...")
        let deleted = conn.deleteMessages(message.chat.id)

        if markovs.hasKey(message.chat.id):
          markovs.del(message.chat.id)

        discard await bot.editMessageText(chatId = $message.chat.id, messageId = sentMessage.messageId,
          text = &"Operation completed. Successfully deleted `{deleted}` messages from my database!",
          parseMode = "markdown"
        )
        return
      except Exception as error:
        discard await bot.sendMessage(message.chat.id, text = "An error occurred. Operation has been aborted.", replyToMessageId = message.messageId)
        raise
    else:
      discard await bot.sendMessage(message.chat.id,
        "If you are sure to delete data in this chat, send `/delete confirm`. *NOTE*: This cannot be reverted",
        parseMode = "markdown")


proc updateHandler(bot: Telebot, u: Update): Future[bool] {.async, gcsafe.} =
  if not u.message.isSome:
      # return true will make bot stop process other callbacks
      return true

  let
    response = u.message.get
    msgUser = response.fromUser.get
    chatId = response.chat.id

  try:
    if response.text.isSome or response.caption.isSome:
      var
        text = if response.text.isSome: response.text.get else: response.caption.get
        splitted = text.split()
        command = splitted[0].strip(chars = {'/'}, trailing = false)
        args = if len(splitted) > 1: splitted[1 .. ^1] else: @[]

      if text.startswith('/'):
        if msgUser.id notin admins and isFlood(chatId):
          return true

        if '@' in command:
          let splittedCommand = command.split('@')
          if splittedCommand[^1].toLower() != botUsername:
            return true
          command = splittedCommand[0]
        await handleCommand(bot, u, command, args)
        return true

      let chat = conn.getOrInsert(database.Chat(chatId: chatId))
      if not chat.enabled:
        return

      if not markovs.hasKeyOrPut(chatId, (newMarkov(@[text]), unixTime())):
        for message in conn.getLatestMessages(chatId = chatId):
          if message.text != "":
            markovs.get(chatId).addSample(message.text)
      else:
        markovs.get(chatId).addSample(text)

      let user = conn.getOrInsert(database.User(userId: msgUser.id))
      conn.addMessage(database.Message(text: text, sender: user, chat: chat))

      if rand(0 .. 100) <= chat.percentage and not isFlood(chatId, rate = 10, seconds = 60): # Max 10 messages per chat per minute
        let generated = markovs.get(chatId).generate()
        if generated.isSome:
          discard await bot.sendMessage(chatId, generated.get())
  except IOError:
    if "Bad Request: have no rights to send a message" in getCurrentExceptionMsg():
      try:
        discard await bot.leaveChat(chatId = $chatId)
      except: discard
    let msg = getCurrentExceptionMsg()
    L.log(lvlError, &"{$typeof(error)}: " & msg)
  except Exception as error:
    let msg = getCurrentExceptionMsg()
    L.log(lvlError, &"{$typeof(error)}: " & msg)


proc main {.async.} =
  let
    configFile = currentSourcePath.parentDir / "../secret.ini"
    config = if fileExists(configFile): loadConfig(configFile)
      else: loadConfig(newStringStream())
    botToken = config.getSectionValue("config", "token", getEnv("BOT_TOKEN"))
    admin = config.getSectionValue("config", "admin", getEnv("ADMIN_ID"))

  conn = initDatabase(MARKOV_DB)
  defer: conn.close()

  if admin != "":
    admins.incl(conn.setAdmin(userId = parseBiggestInt(admin)).userId)
  
  for admin in conn.getBotAdmins():
    admins.incl(admin.userId)

  let bot = newTeleBot(botToken)
  botUsername = (await bot.getMe()).username.get().toLower()

  asyncCheck cleanerWorker()

  discard await bot.getUpdates(offset = -1)
  bot.onUpdate(updateHandler)
  await bot.pollAsync(timeout = 300, clean = true)

when isMainModule:
  when defined(windows):
    if CompileDate != now().format("yyyy-MM-dd"):
      echo "You can't run this on windows after a day"
      quit(1)

  try:
    waitFor main()
  except KeyboardInterrupt:
    echo "\nQuitting...\nProgram has run for ", toInt(epochTime() - uptime), " seconds."
    quit(0)
