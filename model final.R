# This is an unofficial report on model building for predicting words.

# Set options.
options(java.parameters = "-Xmx2g")
options(mc.cores = 1)

# Load libraries.
library(tm)
library(stringi)
library(stringr)
library(plyr)
library(dplyr)
library(reshape2)
library(data.table)
require(microbenchmark)

library(RWeka)

# Set directory.
setwd("~/edu/coursera/Data Science/capstone project/model building")

# Functions: Calculate the smallest number of words needed to cover
# 'perc' percent of vocabulary used in the corpus for tdm.
coverperc <- function(tdm, perc) {
    m <- as.matrix(tdm)
    mfreq <- sort(rowSums(m), decreasing = TRUE)
    all <- round(perc * sum(mfreq), 0)
    n <- 1
    while (sum(head(mfreq, n)) < all) {
        n <- n + 1
    }
    freqwords <- names(head(mfreq, n))
    freqwords <- c(freqwords, "a")
    freqwords <- data.frame(x = sort(freqwords))
    return(freqwords)
}

# Clean line from all words that are not in FreqWords. Replace them
# with newline sign.
cleanSet <- function(lineset) {
    newset <- c()
    for (line in lineset) {
        linesplit <- strsplit(line, " ", fixed = TRUE)[[1]]
        linesplit <- linesplit[!duplicated(linesplit)]
        linesplit <- data.table(x = sort(linesplit), key = "x")
        outwords <- linesplit[!FreqWord]
        if (nrow(outwords) == 0) {
            newline = line
        } else {
            newline <- c()
            outwords <- paste0(outwords$x, collapse = " | ")
            outwords <- paste(" ", outwords, " ", sep = "")
            line <- gsub("^| ", "  ", line)
            line <- gsub("$", "  ", line)
            line <- strsplit(line, split = outwords)[[1]]
            for (lin in line) {
                lin <- trimws(lin)
                if (lin != "") {
                  newline <- c(newline, lin)
                }
            }
        }
        newset <- c(newline, newset)
    }
    return(newset)
}

# Prepare a vector of randomized line numbers covering perc percent of
# the file.
randLines <- function(file, perc, seed) {
    command <- paste("wc -l", file, sep = " ")
    nl <- system(command, intern = TRUE)
    nl <- as.integer(strsplit(nl, split = " ")[[1]][1])
    np <- round(perc * nl, 0)
    set.seed(seed)
    nvec <- sample(c(1:nl), np)
    return(nvec)
}

# Sample perc percent of the corpus file and clean lines if necessary.
sampleLines <- function(file, nvec) {
    linevec <- c()
    i = 1
    for (nv in nvec) {
        line <- scan(file, nlines = 1, skip = nv - 1, what = "character", 
            sep = "\n")
        linevec <- c(linevec, line)
        print(c(i, length(nvec)))
        i = i + 1
    }
    return(linevec)
}

# Tokenization functions
MakeBigram <- function(x) NGramTokenizer(x, Weka_control(min = 2, max = 2))
MakeTrigram <- function(x) NGramTokenizer(x, Weka_control(min = 3, max = 3))
MakeTetragram <- function(x) NGramTokenizer(x, Weka_control(min = 4, max = 4))

# Make Corpus
makeCorpus <- function(vec) {
    vec <- paste0(vec, collapse = "\n")
    vec <- VectorSource(vec)
    vec <- Corpus(vec)
    return(vec)
}

# Reduces the number of frequent terms into pt terms.
keepFreq <- function(dt, pt) {
    gooddata <- data.frame(term = character(0), pred = character(0), freq = numeric(0), 
        wfreq = numeric(0), stringsAsFactors = FALSE)
    lastterm = ""
    nword = 0
    for (i in c(1:nrow(dt))) {
        if (dt$term[i] == lastterm) {
            nword = nword + 1
            if (nword < pt) {
                gooddata[nrow(gooddata) + 1, ] <- dt[i, ]
                lastterm = dt$term[i]
                lastfreq = dt$freq[i]
                lastwfreq = dt$wfreq[i]
            } else {
                if (dt$freq[i] == lastfreq && dt$wfreq[i] == lastwfreq) {
                  gooddata[nrow(gooddata) + 1, ] <- dt[i, ]
                  lastwfreq = dt$wfreq[i]
                }
            }
        } else {
            lastterm = dt$term[i]
            lastfreq = dt$freq[i]
            lastwfreq = dt$wfreq[i]
            nword = 0
            gooddata[nrow(gooddata) + 1, ] <- dt[i, ]
        }
    }
    gooddata <- gooddata[, 1:2]
    gooddata <- aggregate(pred ~ term, data = gooddata, FUN = paste)
    gooddata <- data.table(gooddata)
    return(gooddata)
}

# Change term document matrix into data table, keeping only pt most
# frequent prediction terms.
toDataTable <- function(tdm, nt, MonoMat, pt = 5) {
    mat <- rowSums(as.matrix(tdm))
    gooddata <- data.frame(term = character(0), pred = character(0), freq = numeric(0), 
        wfreq = numeric(0), stringsAsFactors = FALSE)
    for (name in names(mat)) {
        namesplit <- strsplit(name, " ")[[1]]
        term = paste0(head(namesplit, n = nt - 1), collapse = " ")
        pred = tail(namesplit, n = 1)
        if (is.na(MonoMat[pred])) {
            wfreq = 1
        } else {
            wfreq = MonoMat[pred]
        }
        gooddata[nrow(gooddata) + 1, ] <- c(term, pred, mat[name], wfreq)
    }
    gooddata <- data.table(gooddata)
    gooddata$freq <- as.numeric(gooddata$freq)
    gooddata$wfreq <- as.numeric(gooddata$wfreq)
    setorder(gooddata, term, -freq, -wfreq)
    gooddata <- keepFreq(gooddata, pt)
    return(gooddata)
}

# The main prediction function.
predWord <- function(str, model) {
    str <- cleanString(str)
    splitted <- strsplit(str, " ")[[1]]
    lstr <- length(splitted)
    if (lstr < 1) {
        return("No input.")
    }
    if (lstr >= 3) {
        lastwords <- paste0(tail(splitted, n = 3), collapse = " ")
        prediction <- tryCatch(model$TetraPred$pred[model$TetraPred$term == 
            lastwords][[1]], error = function(cond) {
            lstr <<- 2
        })
    }
    if (lstr == 2) {
        lastwords <- paste0(tail(splitted, n = 2), collapse = " ")
        prediction <- tryCatch(model$TriPred$pred[model$TriPred$term == 
            lastwords][[1]], error = function(cond) {
            lstr <<- 1
        })
    }
    if (lstr == 1) {
        lastwords <- tail(splitted, n = 1)
        prediction <- tryCatch(model$BiPred$pred[model$BiPred$term == lastwords][[1]], 
            error = function(cond) {
                lstr <<- 0
            })
    }
    if (lstr == 0) {
        prediction <- model$MostFreq
    }
    return(prediction)
}

# Complete the table up to 5 predicted terms.
compPred <- function(dt, model, pt = 5) {
    gooddata <- data.frame(term = character(0), pred = character(0), stringsAsFactors = FALSE)
    for (term in dt$term) {
        splitterm <- strsplit(term, split = " ")[[1]]
        pred <- dt$pred[dt$term == term][[1]]
        while (length(pred) < pt && length(splitterm) > 1) {
            splitterm <- splitterm[-1]
            newterm <- paste0(splitterm, collapse = " ")
            pred <- c(pred, predWord(newterm, model))
            pred <- pred[!duplicated(pred)]
            if (length(pred) > pt) {
                pred <- pred[1:pt]
            }
        }
        mostfreqloc <- strsplit(model$MostFreq, split = " ")[[1]]
        while (length(pred) < pt && length(mostfreqloc) > 0) {
            pred <- c(pred, head(mostfreqloc, n = 1))
            pred <- pred[!duplicated(pred)]
            mostfreqloc <- mostfreqloc[-1]
        }
        pred <- paste0(pred, collapse = " ")
        gooddata[nrow(gooddata) + 1, ] <- cbind(term, pred)
    }
    gooddata <- data.table(gooddata)
    return(gooddata)
}

# Clean the string input by a user.
cleanString <- function(str) {
    str <- tolower(str)
    str <- gsub("i'm", "i am", str)
    str <- gsub("he's", "he is", str)
    str <- gsub("it's", "it is", str)
    str <- gsub("that's", "that is", str)
    str <- gsub("who's", "who is", str)
    str <- gsub("'re", " are", str)
    str <- gsub("can't", "can not", str)
    str <- gsub("won't", "will not", str)
    str <- gsub("n't", " not", str)
    str <- gsub("'ll", " will", str)
    str <- gsub("'ve", " have", str)
    str <- gsub("'d", " would", str)
    str <- gsub("'n'", " and ", str)
    str <- gsub("o'clock", "of the clock", str)
    str <- gsub("'s ", " ", str)
    str <- gsub("[^a-z ]", "", str)
    str <- stripWhitespace(str)
    return(str)
}

# Prepare a list of data.tables for the predWord function and complete
# them recursively.
makeModel <- function(corpus, pt = 5) {
    # Calculate grams for the train set.
    MonoGram <- TermDocumentMatrix(corpus)
    BiGram <- TermDocumentMatrix(corpus, control = list(tokenize = MakeBigram))
    TriGram <- TermDocumentMatrix(corpus, control = list(tokenize = MakeTrigram))
    TetraGram <- TermDocumentMatrix(corpus, control = list(tokenize = MakeTetragram))
    
    # Prepare predictor tables.
    MonoMat <- rowSums(as.matrix(MonoGram))
    MonoMat["a"] <- max(MonoMat)
    
    BiPred <- toDataTable(BiGram, 2, MonoMat, pt)
    TriPred <- toDataTable(TriGram, 3, MonoMat, pt)
    TetraPred <- toDataTable(TetraGram, 4, MonoMat, pt)
    
    # Determine pt most frequent words in the corpus.
    MostFreq <- names(sort(MonoMat, decreasing = TRUE)[1:pt])
    MostFreq <- paste0(MostFreq, collapse = " ")
    
    model <- list(BiPred = BiPred, TriPred = TriPred, TetraPred = TetraPred, 
        MostFreq = MostFreq)
    
    # Complete recursively the prediction tables using pt predicted terms.
    TetraPred <- compPred(TetraPred, model, pt)
    TriPred <- compPred(TriPred, model, pt)
    BiPred <- compPred(BiPred, model, pt)
    
    model <- list(BiPred = BiPred, TriPred = TriPred, TetraPred = TetraPred, 
        MostFreq = MostFreq)
    return(model)
}

# Calculate accuracy based on a test set.
calcAcc <- function(testset, model) {
    testset <- rowSums(as.matrix(testset))
    pos = 0
    for (name in names(testset)) {
        namesplit <- strsplit(name, " ")[[1]]
        term <- paste0(head(namesplit, n = 3), collapse = " ")
        last <- tail(namesplit, n = 1)
        prediction <- predWord(term, model)
        prediction <- strsplit(prediction, " ")[[1]]
        for (pred in prediction) {
            if (pred == last) {
                pos = pos + 1
            }
        }
    }
    return(pos/length(names(testset)))
}


# ################################
# Main:
# ################################

# Sample lines for Train, Test, and Validation sets.
nvec <- randLines("../newdata/en_US/CleanCorpus.txt", perc = 1, seed = 3003)

CorpSample <- sampleLines("../newdata/en_US/CleanCorpus.txt", nvec[1:70000])
Phrases <- readLines("../newdata/en_US/CleanPhrases.txt")

# Prepare FreqWord of a given coverage.
load("../data/en_US/tdm/MonoGram.RData")
FreqWord <- data.table(coverperc(MonoGram, 0.85))
rm(MonoGram)

# Make partition into Train (80%), Test (10%) and Validation (10%).
lc <- length(CorpSample)
cut1 <- round(lc * 0.8, 0)
cut2 <- round(lc * 0.9, 0)
dTrain <- CorpSample[1:cut1]
dTest <- CorpSample[cut1:cut2]
dValid <- CorpSample[cut2:lc]

# Clean the Train set. Test and Validation should remain uncleaned but
# we test on cleaned anyway.
dTrainClean <- cleanSet(dTrain)
dTestClean <- cleanSet(dTest)
dValidClean <- cleanSet(dValid)

# Prepare corpora for models, Test and Validation.
cTrainPhrase <- makeCorpus(c(dTrainClean, Phrases))

cTest <- makeCorpus(dTest)
cTestClean <- makeCorpus(dTestClean)

cValid <- makeCorpus(dValid)
cValidClean <- makeCorpus(dValidClean)

# Create models with pt predicted terms.
ModelPhrase <- makeModel(cTrainPhrase, pt = 7)

# Test the models.  ModelPhrase
microbenchmark(predWord("where are you", ModelPhrase), times = 1000)
microbenchmark(predWord("about a baby present", ModelPhrase), times = 1000)
microbenchmark(predWord("daf qeqg #@ gjal", ModelPhrase), times = 1000)
microbenchmark(predWord("not", ModelPhrase), times = 1000)

# Calculate accuracy in the test set.
tdmTest <- TermDocumentMatrix(cTest, control = list(tokenize = MakeTetragram))
tdmTestClean <- TermDocumentMatrix(cTestClean, control = list(tokenize = MakeTetragram))

AccTest_ModelPhrase <- calcAcc(tdmTest, ModelPhrase)
AccTestClean_ModelPhrase <- calcAcc(tdmTestClean, ModelPhrase)

# Choose model for application
ModelFinal <- ModelPhrase
save("ModelFinal", file = "/home/mrln/edu/coursera/Data Science/capstone project/predwordapp/ModelFinal.RData")

# Calculate final accuracy in the validation set.
tdmValid <- TermDocumentMatrix(cValid, control = list(tokenize = MakeTetragram))
tdmValidClean <- TermDocumentMatrix(cValidClean, control = list(tokenize = MakeTetragram))

AccValid_ModelFinal <- calcAcc(tdmValid, ModelFinal)
AccValidClean_ModelFinal <- calcAcc(tdmValidClean, ModelFinal)

save.image("~/edu/coursera/Data Science/capstone project/model building/model final.RData")


