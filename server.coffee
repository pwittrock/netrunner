express = require('express')
app = express()
server = require('http').createServer(app)
io = require('socket.io')(server)
stylus = require('stylus')
config = require('./config')
mongoskin = require('mongoskin')
MongoStore = require('connect-mongo')(express)
crypto = require('crypto')
bcrypt = require('bcrypt')
passport = require('passport')
localStrategy = require('passport-local').Strategy
jwt = require('jsonwebtoken')
zmq = require('zmq')

# MongoDB connection
mongoUser = process.env.OPENSHIFT_MONGODB_DB_USERNAME
mongoPassword = process.env.OPENSHIFT_MONGODB_DB_PASSWORD
login = if process.env.OPENSHIFT_MONGODB_DB_PASSWORD then "#{mongoUser}:#{mongoPassword}@" else ""
mongoHost = process.env.OPENSHIFT_MONGODB_DB_HOST || '127.0.0.1'
mongoPort = process.env.OPENSHIFT_MONGODB_DB_PORT || '27017'
appName = process.env.OPENSHIFT_APP_NAME || 'netrunner'
clServer = process.env.CL_SERVER || 'tcp://127.0.0.1:1043'

mongoUrl = "mongodb://#{login}#{mongoHost}:#{mongoPort}/#{appName}"
db = mongoskin.db(mongoUrl)

# Game lobby
gameid = 0
games = {}

swapSide = (side) ->
  if side is "Corp" then "Runner" else "Corp"

removePlayer = (socket) ->
  game = games[socket.gameid]
  if game
    for player, i in game.players
      if player.id is socket.id
        game.players.splice(i, 1)
        break
    if game.players.length is 0
      requester.send(JSON.stringify({action: "remove", gameid: socket.gameid}))
      delete games[socket.gameid]
    socket.leave(socket.gameid)
    socket.gameid = false
    lobby.emit('netrunner', {type: "games", games: games})

joinGame = (socket, gameid) ->
  game = games[gameid]
  if game and game.players.length is 1 and game.players[0].user.username isnt socket.request.user.username
    game.players.push({user: socket.request.user, id: socket.id, side: swapSide(game.players[0].side)})
    socket.join(gameid)
    socket.gameid = gameid
    socket.emit("netrunner", {type: "game", gameid: gameid})
    lobby.emit('netrunner', {type: "games", games: games})

# ZeroMQ
requester = zmq.socket('req')
requester.connect(clServer)
requester.on 'message', (data) ->
  response = JSON.parse(data)
  unless response is "ok"
    lobby.to(response.gameid).emit("netrunner", {type: response.action, state: response})

# Socket.io
io.set("heartbeat timeout", 30000)
io.use (socket, next) ->
  if socket.handshake.query.token
    jwt.verify socket.handshake.query.token, config.salt, (err, user) ->
      socket.request.user = user unless err
  next()

chat = io.of('/chat').on 'connection', (socket) ->
  socket.on 'netrunner', (msg) ->
    msg.date = new Date()
    chat.emit('netrunner', msg)
    db.collection('messages').insert msg, (err, result) ->

lobby = io.of('/lobby').on 'connection', (socket) ->
  lobby.emit('netrunner', {type: "games", games: games})

  socket.on 'disconnect', () ->
    if socket.gameid
      if games[socket.gameid].started
        requester.send(JSON.stringify({action: "notification", gameid: socket.gameid, text: "#{socket.request.user.username} disconnected."}))
      removePlayer(socket)

  socket.on 'netrunner', (msg) ->
    switch msg.action
      when "create"
        game = {date: new Date(), gameid: ++gameid, title: msg.title,\
                players: [{user: socket.request.user, id: socket.id, side: "Corp"}]}
        games[gameid] = game
        socket.join(gameid)
        socket.gameid = gameid
        socket.emit("netrunner", {type: "game", gameid: gameid})
        lobby.emit('netrunner', {type: "games", games: games, notification: "ting"})

      when "leave-lobby"
        socket.to(socket.gameid).emit('netrunner', {type: "say", user: "__system__", text: "#{socket.request.user.username} left the game."})
        removePlayer(socket)

      when "leave-game"
        msg.action = "quit"
        requester.send(JSON.stringify(msg)) if games[socket.gameid].players.length > 1
        removePlayer(socket)

      when "join"
        joinGame(socket, msg.gameid)
        socket.broadcast.to(msg.gameid).emit 'netrunner',
          type: "say"
          user: "__system__"
          notification: "ting"
          text: "#{socket.request.user.username} joined the game."

      when "reconnect"
        game = games[msg.gameid]
        if game and game.started
          joinGame(socket, msg.gameid)
          requester.send(JSON.stringify({action: "notification", gameid: socket.gameid, text: "#{socket.request.user.username} reconnected."}))

      when "say"
        lobby.to(msg.gameid).emit("netrunner", {type: "say", user: socket.request.user, text: msg.text})

      when "swap"
        for player in games[socket.gameid].players
          player.side = swapSide(player.side)
          player.deck = null
        lobby.to(msg.gameid).emit('netrunner', {type: "games", games: games})

      when "deck"
        for player in games[socket.gameid].players
          if player.user.username is socket.request.user.username
            player.deck = msg.deck
            break
        lobby.to(msg.gameid).emit('netrunner', {type: "games", games: games})

      when "start"
        game = games[socket.gameid]
        if game
          game.started = true
          msg = games[socket.gameid]
          msg.action = "start"
          msg.gameid = socket.gameid
          requester.send(JSON.stringify(msg))
          lobby.emit('netrunner', {type: "games", games: games})

      when "do"
        try
          requester.send(JSON.stringify(msg))
        catch err
          console.log(err)

# Express config
app.configure ->
  app.use express.favicon(__dirname + "/resources/public/img/jinteki.ico")
  app.set 'port', 1042
  app.set 'ipaddr', "0.0.0.0"
  app.use express.methodOverride() # provide PUT DELETE
  app.use express.cookieParser()
  app.use express.urlencoded()
  app.use express.json()
  app.use express.session
    store: new MongoStore(url: mongoUrl)
    secret: config.salt
    cookie: { maxAge: 2592000000 } # 30 days
  app.use passport.initialize()
  app.use passport.session()
  app.use stylus.middleware({src: __dirname + '/src', dest: __dirname + '/resources/public'})
  app.use express.static(__dirname + '/resources/public')
  app.use app.router

# Auth
passport.use new localStrategy (username, password, done) ->
  db.collection('users').findOne {username: RegExp("^#{username}$", "i")}, (err, user) ->
    return done(err) if err or not user
    if bcrypt.compareSync(password, user.password)
      done(null, {username: user.username, emailhash: user.emailhash, _id: user._id})
    else
      return done(null, false)

passport.serializeUser (user, done) ->
  done(null, user._id) if user

passport.deserializeUser (id, done) ->
  db.collection('users').findById id, (err, user) ->
    console.log err if err
    done(err, {username: user.username, emailhash: user.emailhash, _id: user._id})

# Routes
app.post '/login', passport.authenticate('local'), (req, res) ->
  db.collection('users').update {username: req.user.username}, {$set: {lastConnection: new Date()}}, (err) ->
    throw err if err
    res.json(200, {user: req.user})

app.get '/logout', (req, res) ->
  req.logout()
  res.redirect('/')

app.post '/register', (req, res) ->
  db.collection('users').findOne username: req.body.username, (err, user) ->
    if user
      res.send {message: 'Username taken'}, 422
    else
      email = req.body.email.trim().toLowerCase()
      req.body.emailhash = crypto.createHash('md5').update(email).digest('hex')
      req.body.registrationDate = new Date()
      req.body.lastConnection = new Date()
      bcrypt.hash req.body.password, 3, (err, hash) ->
        req.body.password = hash
        db.collection('users').insert req.body, (err) ->
          res.send "error: #{err}" if err
          req.login req.body, (err) -> next(err) if err
          db.collection('decks').find({username: '__demo__'}).toArray (err, demoDecks) ->
            throw err if err
            for deck in demoDecks
              delete deck._id
              deck.username = req.body.username
            db.collection('decks').insert demoDecks, (err, newDecks) ->
              throw err if err
              res.json(200, {user: req.user, decks: newDecks})

app.get '/check/:username', (req, res) ->
  db.collection('users').findOne username: req.params.username, (err, user) ->
    if user
      res.send {message: 'Username taken'}, 422
    else
      res.send {message: 'OK'}, 200

app.get '/messages/:channel', (req, res) ->
  db.collection('messages').find({channel: req.params.channel}).sort(date: -1).limit(100).toArray (err, data) ->
    throw err if err
    res.json(200, data.reverse())

app.get '/data/decks', (req, res) ->
  if req.user
    db.collection('decks').find({username: req.user.username}).toArray (err, data) ->
      throw err if err
      res.json(200, data)
  else
    db.collection('decks').find({username: "__demo__"}).toArray (err, data) ->
      throw err if err
      delete deck._id for deck in data
      res.json(200, data)

app.post '/data/decks', (req, res) ->
  deck = req.body
  if req.user
    deck.username = req.user.username
    if deck._id
      id = deck._id
      delete deck._id
      db.collection('decks').update {_id: mongoskin.helper.toObjectID(id)}, deck, (err) ->
        console.log(err) if err
        res.send {message: 'OK'}, 200
    else
      db.collection('decks').insert deck, (err, data) ->
        console.log(err) if err
        res.json(200, data[0])
  else
    res.send {message: 'Unauthorized'}, 401

app.post '/data/decks/delete', (req, res) ->
  deck = req.body
  if req.user
    db.collection('decks').remove {_id: mongoskin.helper.toObjectID(deck._id), username: req.user.username}, (err) ->
      res.send {message: 'OK'}, 200
  else
    res.send {message: 'Unauthorized'}, 401

app.get '/data/:collection', (req, res) ->
  db.collection(req.params.collection).find().sort(_id: 1).toArray (err, data) ->
    throw err if err
    delete d._id for d in data
    res.json(200, data)

app.get '/data/:collection/:field/:value', (req, res) ->
  filter = {}
  filter[req.params.field] = req.params.value
  db.collection(req.params.collection).find(filter).toArray (err, data) ->
    console.error(err) if err
    delete d._id for d in data
    res.json(200, data)

app.configure 'development', ->
  console.log "Dev environment"
  app.get '/*', (req, res) ->
    if req.user
      db.collection('users').update {username: req.user.username}, {$set: {lastConnection: new Date()}}, (err) ->
      token = jwt.sign(req.user, config.salt)
    res.render('index.jade', { user: req.user, env: 'dev', token: token})

app.configure 'production', ->
  console.log "Prod environment"
  app.get '/*', (req, res) ->
    if req.user
      db.collection('users').update {username: req.user.username}, {$set: {lastConnection: new Date()}}, (err) ->
      token = jwt.sign(req.user, config.salt, {expiresInMinutes: 360})
    res.render('index.jade', { user: req.user, env: 'prod', token: token})

# Server
terminate = () ->
  process.exit(1)
  console.log("#{Date(Date.now())}: Node server stopped.")

process.on('exit', terminate)

for signal in ['SIGHUP', 'SIGINT', 'SIGQUIT', 'SIGILL', 'SIGTRAP', 'SIGABRT',
               'SIGBUS', 'SIGFPE', 'SIGUSR1', 'SIGSEGV', 'SIGUSR2', 'SIGTERM']
  process.on(signal, terminate)

process.on 'uncaughtException', (err) ->
  console.log(err.stack)

server.listen app.get('port'), app.get('ipaddr'), ->
  console.log(new Date().toString() + ": Express server listening on port " + app.get('port'))
