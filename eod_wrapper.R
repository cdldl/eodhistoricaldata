### FIXME
# Measure the total time when it's over for eod.
# Make a diff of the folder and download what's missing
# Batch downloads with estimated time displayed + space
# Change the directory + download only Common Stock
###

list.of.packages <- c("data.table","RCurl","jsonlite","httr","bit64","doMC")
new.packages <- list.of.packages[!(list.of.packages %in% installed.packages()[,"Package"])]
if(length(new.packages)) install.packages(new.packages)
lapply(list.of.packages, require, character.only = TRUE)

api_token = 'YOUR-TOKEN'
path_output = "YOUR-FOLDER"
cores = detectCores() - 10
global_api_minute_limit = 2000
daily_limit = fromJSON(getURL(paste0('https://eodhistoricaldata.com/api/user/?api_token=', 
                                     api_token)))
global_api_daily_limit = daily_limit$dailyRateLimit - daily_limit$apiRequests

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
  # df= copy(earn)
  df2 = data.table()
  for (col in names(df)) {
    df[,paste0(col):=lapply(get(col), function(x) replace(x, is.null(x), NA))]
    raw = if( (is.numeric(df[[col]]) | is.character(df[[col]]) | is.na(df[[col]][1])) & length(df[[col]])<=1) df[[col]] else do.call(c,df[[col]])
    raw <- tryCatch(as.numeric(raw), warning = function(w) raw)
    df2[,paste0(col):=raw]
  }
  df2
}

getFundamentals <- function(fund_data) {
  # fund_data = copy(parsed_data)
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

get_fundamentals = function(exchange, tickers, write_to_disk=T, overwrite=F) {
  # exchange = 'US'; tickers = us_tickers #[Type == 'Common Stock']$Code[1:1001]
  api_call_count = 10
  
  # Check if already saved
  if(!overwrite) {
    already_output = list.files(paste0(path_output,exchange),full.names=T) 
    to_output = paste0(path_output,exchange,'/',tickers,'.csv')
    tickers = tickers[!to_output %in% already_output]
  }
  
  # Create batches
  batch_size = global_api_minute_limit/api_call_count
  ticker_batches <- split(tickers, ceiling(seq_along(tickers) / batch_size))
  
  all_fundamentals = list()
  for(i in seq(ticker_batches)) {
    if(global_api_daily_limit < 0) return('API limit reached')
    
    ticker_batch = ticker_batches[[i]]
    url_batch = paste0('https://eodhistoricaldata.com/api/fundamentals/',
                           ticker_batch, '.', exchange,'?api_token=')
    response = getURL(paste0(url_batch,api_token))
    if(length(ticker_batches) > 1 & (i != length(ticker_batches))) Sys.sleep(60)
    global_api_daily_limit = global_api_daily_limit - length(url_batch) * api_call_count
    
    fundamentals = mclapply(1:length(url_batch),
                          function(x) {
                            parsed_data <- tryCatch(fromJSON(response[x]), 
                                                    error = function(e) e)
                            if(is(parsed_data,'error')) return(data.table())
                            data = getFundamentals(parsed_data)
                            data[,ticker:=tickers[x]]
                            data[,Sector:=parsed_data$General$Sector]
                            data[,Industry:=parsed_data$General$Industry]
                            data[,GicSector:=parsed_data$General$GicSector]
                            data[,GicIndustry:=parsed_data$General$GicIndustry]
if(write_to_disk) fwrite(data, paste0(path_output,
                                      exchange,'/',tickers[x],'_fund.csv'))
                            data},mc.cores = cores)
    all_fundamentals = append(all_fundamentals, fundamentals)
  }
  
  # Merge fundamentals
  all_cols <- unique(unlist(lapply(all_fundamentals, colnames)))
  all_fundamentals = lapply(all_fundamentals, function(x) {
    if (length(colnames(x)) < length(all_cols)) {
      missing_cols <- setdiff(all_cols,colnames(x))
      x[,paste0(missing_cols):=NA]
    }
    x = setcolorder(x, sort(colnames(x)))
    x
  })
  all_fundamentals = do.call(rbind, all_fundamentals)
  return(all_fundamentals)
}

get_eod = function(exchange, tickers, write_to_disk=T, overwrite=F) {
  #write_to_disk=T; overwrite=F
  
  if(length(tickers)>100) {
    load_on_disk = F
    write_to_disk = T
    print('writing to disk instead because length(tickers) > 100')
  } else {
    load_on_disk = T
  }

  api_call_count = 1
  max_ticker_per_batch = 500
  rate_limit = global_api_minute_limit
  batch_size = min(max_ticker_per_batch, global_api_minute_limit/api_call_count)
  
  # Check if already saved
  if(!overwrite) {
    already_output = list.files(paste0(path_output,exchange),full.names=T) 
    to_output = paste0(path_output,exchange,'/',tickers,'.csv')
    tickers = tickers[!to_output %in% already_output]
  }

  all_eods = data.table()
  while(length(tickers)) {
    # Create batch
    ticker_batches <- split(tickers, ceiling(seq_along(tickers) / batch_size))
    tickers = NULL
    i = 1
    # check the bad urls
    while(i <= length(ticker_batches)) {
      if(global_api_daily_limit < 0) return('API limit reached')
      
      # Make ticker batch
      ticker_batch = ticker_batches[[i]]
      url_batch = paste0('https://eodhistoricaldata.com/api/eod/',
                            ticker_batch,'.', exchange,'?api_token=')
      
      response = getURL(paste0(url_batch,api_token),header=T)
      minute_last_request = as.POSIXlt(Sys.time())$min
      
      # Process responses
      results = mclapply(1:length(response),function(i) {
          #print(i)
        tryCatch({
          x= response[i]
          headers <- strsplit(x, "\r\n")[[1]]
          # Get the rate limit
          rate_limit <- grep("^X-RateLimit-Remaining:", headers[1:(length(headers)-1)], value = TRUE)
          rate_limit = as.numeric(gsub('X-RateLimit-Remaining: ',"",rate_limit))
          # Check if ticker has to be done again
          redo = F
          if(length(grep('429 Too Many Requests', headers[length(headers)])) 
             | headers[length(headers)] %in% c("</html>",'')) return(list(redo=T,rate_limit=rate_limit, data=data.table()))
          if(length(grep('Ticker Not Found', headers[length(headers)]))) return(list(redo=F,rate_limit=rate_limit, data=data.table()))
          # Get data
          ticker_name = strsplit(url_batch[i],'/|[.]')[[1]][7]
          data = tryCatch(fread(headers[length(headers)]), error = function(e) e)
          if(!is(data,'error')) {
            data[,ticker:=ticker_name]
            if(write_to_disk) fwrite(data, paste0(path_output,
                                                  exchange,'/',ticker_name,'.csv'))
            return(list(redo=redo,rate_limit=rate_limit, data=data))
          } else {
            return(list(redo=redo,rate_limit=rate_limit, data=data.table()))
          }
        }, error = function(e) {
            return(list(redo=T,rate_limit=NA, data=data.table()))
          })
      }, mc.cores=cores)
        
      # Get the tickers that did not work
      if(class(results) == 'vector') {
        tickers = c(tickers,do.call(rbind,strsplit(url_batch,'/|[.]'))[,7])
        i = i +1
        next()
      } 
      redos = tryCatch(sapply(results, function(x) x$redo), error = function(e) rep(T, length(response)))
      tickers = c(tickers,do.call(rbind,strsplit(url_batch[which(redos==T)],'/|[.]'))[,7])
      
      # Update rate limit
      rate_limits = sapply(results, function(x) x$rate_limit)
      rate_limit = if(is(rate_limits, 'list')) min(c(rate_limit - batch_size, do.call(c,rate_limits)),na.rm=T) else min(c(rate_limit - batch_size,rate_limits),na.rm=T)
      global_api_daily_limit = global_api_daily_limit - 
        (batch_size - length(which(redos==T))) * api_call_count
      
      # Get data
      eods = lapply(results, function(x) x$data)
      eods = eods[sapply(eods,nrow) != 0]
      if(load_on_disk == T) all_eods = rbind(all_eods, do.call(rbind,eods))
      
      # Pause for minute API limit
      while(rate_limit < batch_size & minute_last_request == as.POSIXlt(Sys.time())$min) {
        Sys.sleep(1)
      }
      i = i + 1
    }
  }
  return(all_eods)
}

get_intra = function(exchange, tickers, starting_date = '2000-01-01',
                     end_date = Sys.time(), write_to_disk=T) {
  # exchange = 'US'; tickers = us_tickers#[Type == 'Common Stock']$Code[1:6]
  api_call_count = 5
  if(exchange == 'US') interval = '1m' else interval = '5m'
  min_date = as.numeric(as.POSIXct(starting_date,tz='UTC'))
  max_date = as.numeric(as.POSIXct(format(end_date, tz = "UTC")))
  
  endpoint_intra = paste0('https://eodhistoricaldata.com/api/intraday/',
                          tickers,'.', exchange,'?api_token=')
  queries = NULL
  while(max_date > min_date) {
    tmp_date = max_date - 120 * 24 * 60 * 60
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
    intras = mclapply(1:length(url_batch),
                  function(i) {x = fread(response[i])
                  ticker_name = strsplit(url_batch[i],'/|[.]US')[[1]][6]
                  x[,ticker:=ticker_name]
if(write_to_disk) fwrite(x, paste0(path_output,exch,ticker_name,'_intra.csv'), append = T)
                  x}
                  ,mc.cores = cores)
    all_intras = append(all_intras, intras)
  }
  
  removal = sapply(all_intras, function(x) nrow(x) == 0)
  all_intras = all_intras[!removal]
  all_intras = do.call(rbind,all_intras)
  return(all_intras)
}

main = function() {
  exchanges = get_exchanges()
  for(exchange in exchanges$Code) {
    print(exchange)
    if(!file.exists(paste0(path_output,exchange))) dir.create(paste0(path_output,exchange),recursive=T)
    tickers = get_tickers(exchange)
    if(length(tickers)) {
      eods = get_eod(exchange, tickers$Code)
      #fund = get_fundamentals(exchange, tickers[Type == 'Common Stock']$Code)
      #intras = get_intra(exchange, tickers$Code)
    } 
  }
}

main()
