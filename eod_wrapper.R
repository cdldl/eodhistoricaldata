### FIXME
# Batch downloads with estimated time displayed + space
# deal with response errors
# Function to write to disk
# mclapply/parallel lapply for linux
# Add from and to for intra
###

list.of.packages <- c("data.table","RCurl","jsonlite","httr","bit64")
new.packages <- list.of.packages[!(list.of.packages %in% installed.packages()[,"Package"])]
if(length(new.packages)) install.packages(new.packages)
lapply(list.of.packages, require, character.only = TRUE)

api_token = 'YOUR-TOKEN'
global_api_daily_limit = 100000
global_api_minute_limit = 2000

get_exchanges = function() {
  api_call_count = 1
  global_api_daily_limit = global_api_daily_limit - api_call_count
  if(global_api_daily_limit < 0) return('API limit reached')
  endpoint_exchange = 
    'https://eodhistoricaldata.com/api/exchanges-list/?api_token='
  response = getURL(paste0(endpoint_exchange,api_token))
  parsed_data <- fromJSON(response)
  parsed_data
}

get_tickers = function(exchange) {
  #exchange = 'US'
  api_call_count = 1
  global_api_daily_limit = global_api_daily_limit - api_call_count
  if(global_api_daily_limit < 0) return('API limit reached')
  endpoint_tickers  = 
    paste0('https://eodhistoricaldata.com/api/exchange-symbol-list/', 
           exchange,'?api_token=')
  response = getURL(paste0(endpoint_tickers,api_token))
  parsed_data <- fread(response)
  parsed_data
} 

parseRawFundamentals = function(df) {
  df2 = data.table()
  for (col in names(df)) {
    df[,paste0(col):=lapply(get(col), function(x) replace(x, is.null(x), NA))]
    raw = if( (is.character(df[[col]]) | is.na(df[[col]][1])) & length(df[[col]])<=1) df[[col]] else do.call(c,df[[col]])
    raw <- tryCatch(as.numeric(raw), warning = function(w) raw)
    df2[,paste0(col):=raw]
  }
  df2
}

getFundamentals <- function(fund_data) {
  bal <- t(fund_data$Financials$Balance_Sheet$quarterly)
  bal = as.data.table(do.call(rbind, bal))
  bal = parseRawFundamentals(bal)
  if(length(bal)==0) return(data.table())
  cf <- t(fund_data$Financials$Cash_Flow$quarterly)
  cf = as.data.table(do.call(rbind, cf))
  cf = parseRawFundamentals(cf)
  inc <- t(fund_data$Financials$Income_Statement$quarterly)
  inc = as.data.table(do.call(rbind, inc))
  inc = parseRawFundamentals(inc)
  earn <- t(fund_data$Earnings$History)
  earn = as.data.table(do.call(rbind, earn))
  earn = parseRawFundamentals(earn)
  
  # Merging them together
  data_tables <- list(bal, cf, inc, earn)
  data_tables <- data_tables[sapply(data_tables, function(dt) !is.null(dt) && nrow(dt) > 0)]
  
  # Merge the non-null and non-empty data.tables by date
  if (length(data_tables) > 0) {
    df <- Reduce(function(x, y) merge(x, y, by = "date", all = TRUE), data_tables)
  } else {
    df <- NULL
  }
  
  # Dropping redundant date and duplicate columns
  dup_cols <- grep("[.]y", names(df), ignore.case = TRUE, value = TRUE)
  df <- df[, !(names(df) %in% dup_cols),with=F]
  
  df = df[order(date)]
  df = df[date <= Sys.Date()]
  return(df)
}

get_fundamentals = function(exchange, tickers) {
  # exchange = 'US'; tickers = us[Type == 'Common Stock']$Code[1:1001]
  api_call_count = 10
  batch_size = global_api_minute_limit/api_call_count
  ticker_batches <- split(tickers, ceiling(seq_along(tickers) / batch_size))
  
  all_fundamentals = list()
  for(i in seq(url_batches)) {
    if(global_api_daily_limit < 0) return('API limit reached')
    
    ticker_batch = ticker_batches[[i]]
    url_batch = paste0('https://eodhistoricaldata.com/api/fundamentals/',
                           ticker_batch, '.', exchange,'?api_token=')
    response = getURL(paste0(url_batch,api_token))
    if(length(url_batches) > 1 & (i != length(url_batches))) Sys.sleep(60)
    global_api_daily_limit = global_api_daily_limit - length(url_batch) * api_call_count
    
    fundamentals = lapply(1:length(url_batch),
                          function(i) {
                            print(i)
                            parsed_data <- fromJSON(response[i])
                            data = getFundamentals(parsed_data)
                            data[,ticker:=tickers[i]] })
    all_fundamentals = append(all_fundamentals, fundamentals)
  }
  
  # Merge columns
  all_cols <- unique(unlist(lapply(all_fundamentals, colnames)))
  max_cols <- max(sapply(all_fundamentals, function(x) length(colnames(x))))
  all_fundamentals = lapply(all_fundamentals, function(x) {
    if (length(colnames(x)) < max_cols) {
      missing_cols <- setdiff(all_cols,colnames(x))
      x[,paste0(missing_cols):=NA]
    }
    x = setcolorder(dt, sort(colnames(x)))
    x
  })
  all_fundamentals = do.call(rbind, all_fundamentals)
  return(all_fundamentals)
}

get_eod = function(exchange, tickers) {
  api_call_count = 1
  batch_size = global_api_minute_limit/api_call_count
  ticker_batches <- split(tickers, ceiling(seq_along(tickers) / batch_size))
  
  for(i in seq(url_batches)) {
    if(global_api_daily_limit < 0) return('API limit reached')
    
    ticker_batch = ticker_batches[[i]]
    url_batch = paste0('https://eodhistoricaldata.com/api/eod/',
                          ticker_batch,'.', exchange,'?api_token=')
    
    response = getURL(paste0(url_batch,api_token))
    if(length(url_batches) > 1 & (i != length(url_batches))) Sys.sleep(60)
    global_api_daily_limit = global_api_daily_limit - length(url_batch) * api_call_count
    
    eods = lapply(1:length(url_batch),
         function(i) {x = fread(response[i])
         x[,ticker:=ticker_batch[i]]})
    eods = do.call(rbind,eods)
  }
  return(eods)
}

get_intra = function(exchange, tickers) {
  # exchange = 'US'; tickers = us[Type == 'Common Stock']$Code[1:6]
  api_call_count = 5
  if(exchange == 'US') interval = '1m' else interval = '5m'
  min_date = as.numeric(as.POSIXct('2000-01-01',tz='UTC'))
  max_date = as.numeric(as.POSIXct(format(Sys.time(), tz = "UTC")))
  
  endpoint_intra = paste0('https://eodhistoricaldata.com/api/intraday/',
                          tickers,'.', exchange,'?api_token=')
  queries = NULL
  while(max_date > min_date) {
    tmp_date = max_date - 120 * 24 * 60 * 60
    print(paste0(as.POSIXct(tmp_date) ,' ', as.POSIXct(max_date)))
    tmp_query = paste0(endpoint_intra,api_token,'&interval=',interval,'&from=',
                       tmp_date,'&to=',max_date)
    queries = c(queries, tmp_query)
    max_date = tmp_date
  }
  queries
  batch_size = global_api_minute_limit/api_call_count
  url_batches <- split(queries, ceiling(seq_along(queries) / batch_size))
  all_intras = list()
  for(i in seq(url_batches)) {
    if(global_api_daily_limit < 0) return('API limit reached')
    url_batch = url_batches[[i]]
    response = getURL(url_batch)
    if(length(url_batches) > 1 & (i != length(url_batches))) Sys.sleep(60)
    global_api_daily_limit = global_api_daily_limit - length(url_batch) * api_call_count
    intras = lapply(1:length(url_batch),
                  function(i) {x = fread(response[i])
                  ticker_name = strsplit(url_batch[i],'/|[.]US')[[1]][6]
                  x[,ticker:=ticker_name]})
    all_intras = append(all_intras, intras)
  }
  
  removal = sapply(all_intras, function(x) nrow(x) == 0)
  all_intras = all_intras[!removal]
  all_intras = do.call(rbind,all_intras)
  return(all_intras)
}

if(F) {
  response = getURL(paste0(endpoint_eod,api_token),.encoding = "UTF-8", header = TRUE)
  headers <- strsplit(response, "\r\n")[[1]]
  rate_limit <- grep("^X-RateLimit-Remaining:", headers[1:(length(headers)-1)], value = TRUE)
  rate_limit = as.numeric(gsub('X-RateLimit-Remaining: ',"",rate_limit))
}