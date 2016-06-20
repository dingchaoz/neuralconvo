--[[
Format movie dialog data as a table of line 1:

  { {word_ids of character1}, {word_ids of character2} }

Then flips it around and get the dialog from the other character's perspective:

  { {word_ids of character2}, {word_ids of character1} }

Also builds the vocabulary.
]]-- 

local DataSet = torch.class("neuralconvo.DataSet")
local xlua = require "xlua"
local tokenizer = require "tokenizer"
local list = require "pl.List"

function DataSet:__init(samples_file, options)
  options = options or {}

  self.examplesFilename = "data/examples.t7"

  -- Discard words with lower frequency then this
  self.vocabSize = options.vocabSize or -1

  -- Maximum number of words in an example sentence
  self.maxExampleLen = options.maxExampleLen or 25

  -- Load only first fews examples (approximately)
  self.loadFirst = options.loadFirst or 0

  self.examples = {}
  self.examplesCount = 0
  self.samples_file = csvigo.load{path=samples_file,mode='large'}
end

function DataSet:load(vocabOnly)
  local filename = "data/vocab.t7"

  if path.exists(filename) then
    print("Loading vocabulary from " .. filename .. " ...")
    local data = torch.load(filename)
    self.word2id = data.word2id
    self.id2word = data.id2word
    self.wordsCount = data.wordsCount
    self.goToken = data.goToken
    self.eosToken = data.eosToken
    self.unknownToken = data.unknownToken
  else
    print("" .. filename .. " not found")
    self:buildVocab()
    print("\nWriting " .. filename .. " ...")
    torch.save(filename, {
      word2id = self.word2id,
      id2word = self.id2word,
      wordsCount = self.wordsCount,
      goToken = self.goToken,
      eosToken = self.eosToken,
      unknownToken = self.unknownToken
      })
  end
  if vocabOnly then
    return
  end
  print "-- Loading samples"
  self:readSamples()
  self:shuffleExamples()
end

function DataSet:buildVocab()
  -- Table for keeping track of word frequency
  self.wordFreqs = {}
  self.word2id = {}
  self.id2word = {}
  self.wordsCount = 0
  
  -- Add magic tokens
  self.goToken = self:addWordToVocab("<go>") -- Start of sequence
  self.eosToken = self:addWordToVocab("<eos>") -- End of sequence
  self.unknownToken = self:addWordToVocab("<unknown>") -- Word dropped from vocabulary

  print("-- Build vocab")
  
  local nb_samples = #self.samples_file
  if self.loadFirst > 0 then
    nb_samples = self.loadFirst
  end
  
  for i=2, nb_samples do
    self:countWords(self.samples_file[i][1])
    self:countWords(self.samples_file[i][2])
    if i % 10000 == 0 then
      xlua.progress(i,nb_samples)
    end
  end
  
  for word,freq in tablex.sortv(self.wordFreqs,function(x,y) return x>y end) do
    nWordId = self:addWordToVocab(word)
    if self.vocabSize > 0 and nWordId >= self.vocabSize then
      break
    end
  end
end

function DataSet:shuffleExamples()
  print("-- Shuffling ")
  newIdxs = torch.randperm(#self.examples)
  local sExamples = {}
  for i, sample in ipairs(self.examples) do
    sExamples[i] = self.examples[newIdxs[i]]
  end
  self.examples = sExamples
  collectgarbage()
end

function DataSet:readSamples()
  local nb_samples = #self.samples_file
  if self.loadFirst > 0 then
    nb_samples = self.loadFirst
  end
  
  for i=2, nb_samples do
    self:processSample(self.samples_file[i][2],self.samples_file[i][1])
    if i % 10000 == 0 then
      xlua.progress(i,nb_samples)
    end
  end

  self.examplesCount = #self.examples
end

function DataSet:batches(size)
  local examplesit = pairs(self.examples)
  local done = false
  local cursor = 0

  return function()
    if done then
      return
    end

    local inputSeqs,targetSeqs = {},{}
    local maxInputSeqLen,maxTargetOutputSeqLen = 0,0

    for i = 1, size do
      local _,example = next(self.examples,cursor)
      cursor = cursor + 1
      if example == nil then
        done = true
        break
      end
      inputSeq,targetSeq = unpack(example)
      if inputSeq:size(1) > maxInputSeqLen then
        maxInputSeqLen = inputSeq:size(1)
      end
      if targetSeq:size(1) > maxTargetOutputSeqLen then
        maxTargetOutputSeqLen = targetSeq:size(1)
      end
      table.insert(inputSeqs, inputSeq)
      table.insert(targetSeqs, targetSeq)
    end
    
    local encoderInputs,decoderInputs,decoderTargets = nil,nil,nil
    if size == 1 then
      encoderInputs = torch.IntTensor(maxInputSeqLen):fill(0)
      decoderInputs = torch.IntTensor(maxTargetOutputSeqLen-1):fill(0)
      decoderTargets = torch.IntTensor(maxTargetOutputSeqLen-1):fill(0)
    else
      encoderInputs = torch.IntTensor(maxInputSeqLen,size):fill(0)
      decoderInputs = torch.IntTensor(maxTargetOutputSeqLen-1,size):fill(0)
      decoderTargets = torch.IntTensor(maxTargetOutputSeqLen-1,size):fill(0)
    end
    
    for samplenb = 1, #inputSeqs do
      for word = 1,inputSeqs[samplenb]:size(1) do
        eosOffset = maxInputSeqLen - inputSeqs[samplenb]:size(1) -- for left padding
        if size == 1 then
          encoderInputs[word] = inputSeqs[samplenb][word]
        else
          encoderInputs[word+eosOffset][samplenb] = inputSeqs[samplenb][word]
        end
      end
    end
    
    for samplenb = 1, #targetSeqs do
      trimmedEosToken = targetSeqs[samplenb]:sub(1,-2)
      for word = 1, trimmedEosToken:size(1) do
        if size == 1 then
          decoderInputs[word] = trimmedEosToken[word]
        else
          decoderInputs[word][samplenb] = trimmedEosToken[word]
        end
      end
    end
    
    for samplenb = 1, #targetSeqs do
      trimmedGoToken = targetSeqs[samplenb]:sub(2,-1)
      for word = 1, trimmedGoToken:size(1) do
        if size == 1 then
          decoderTargets[word] = trimmedGoToken[word]
        else
          decoderTargets[word][samplenb] = trimmedGoToken[word]
        end
      end
    end

    return encoderInputs,decoderInputs,decoderTargets
  end
end

function DataSet:processSample(sampleInput, sampleTarget)
  if sampleTarget then
    local inputIds = self:visitText(sampleInput)
    local targetIds = self:visitText(sampleTarget)

    if inputIds and targetIds then
      -- Revert inputs
      inputIds = list.reverse(inputIds)

      table.insert(targetIds, 1, self.goToken)
      table.insert(targetIds, self.eosToken)

      table.insert(self.examples, { torch.IntTensor(inputIds), torch.IntTensor(targetIds) })
    end
  end
end

function DataSet:visitText(text)
  local words = {}

  if text == "" then
    return
  end

  for t, word in tokenizer.tokenize(text) do
    local cWord = self.word2id[word:lower()]
    if not cWord then
      cWord = self.unknownToken
    end
    table.insert(words, cWord)
    -- Only keep the first sentence
    if t == "endpunct" or #words >= self.maxExampleLen then
      break
    end
  end

  if #words == 0 then
    return
  end

  return words
end

function DataSet:countWords(sentence)
  --if text == "" then
  --  return
  --end
  for t, word in tokenizer.tokenize(sentence) do
    local lword = word:lower()
    if self.wordFreqs[lword] == nil then
      self.wordFreqs[lword] = 0
    end
    self.wordFreqs[lword] = self.wordFreqs[lword] + 1
  end
end

function DataSet:addWordToVocab(word)
  word = word:lower()
  self.wordsCount = self.wordsCount + 1
  self.word2id[word] = self.wordsCount
  self.id2word[self.wordsCount] = word
  return self.wordsCount
end
