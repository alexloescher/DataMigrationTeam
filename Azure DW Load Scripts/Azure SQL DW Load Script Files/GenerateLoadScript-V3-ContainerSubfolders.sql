/***This Artifact belongs to the Data SQL Ninja Engineering Team***/
declare @schema varchar(10) = 'STAGE'
declare @sourceschema varchar(128) = 'SRC_POC_' + @schema
declare @targetschema varchar(128) = 'TARG_POC_' + @schema
declare @blobstore varchar(100) = '<account>.blob.core.windows.net'

set nocount on

-- ensure your data warehouse has a master key
-- CREATE MASTER KEY;

-- Use your blob storage key to provide SQL DW access to blob storage
if not exists(select * from [sys].[database_credentials] where [name]='AzureStorageCredential')
	CREATE DATABASE SCOPED CREDENTIAL AzureStorageCredential WITH IDENTITY = 'SHARED ACCESS SIGNATURE', SECRET = 'your key here...=='

-- Create the file format definition
if not exists(select * from [sys].[external_file_formats] where [name]='TextFileFormat')
	CREATE EXTERNAL FILE FORMAT TextFileFormat WITH (FORMAT_TYPE = DELIMITEDTEXT, FORMAT_OPTIONS (FIELD_TERMINATOR = '0x01', --STRING_DELIMITER = '', 
																							   USE_TYPE_DEFAULT = FALSE), DATA_COMPRESSION = 'org.apache.hadoop.io.compress.GzipCodec')

declare @objectid int, @table varchar(128), @colid int, @column varchar(128), @type varchar(128), @length smallint, @precision tinyint, @scale tinyint, @nullable bit, @colstr varchar(150)
declare @cmd varchar(max), @distcol varchar(128), @disttype varchar(50)
declare @trows int = 0, @trow int = 1, @crows int = 0, @crow int = 1, @start datetime, @tblrows bigint

-- Ensure target schema exists
if not exists(select * from sys.schemas where name = @targetschema)
 begin
	select @cmd = 'CREATE SCHEMA ' + @targetschema
	exec(@cmd)
 end
-- Check external table schema exists
if not exists(select * from sys.schemas where name = 'ASB')
 	exec('CREATE SCHEMA ASB')

-- cleanup of any previous failed run
IF OBJECT_ID('tempdb..#tables') IS NOT NULL
	DROP TABLE #tables
IF OBJECT_ID('tempdb..#columns') IS NOT NULL
	DROP TABLE #columns

create table #tables
(
	rowid int not null,
	objectid int not null,
	[table] varchar(128) not null
) 
WITH ( HEAP , DISTRIBUTION = ROUND_ROBIN )

create table #columns
(
	colid int,
	[column] varchar(128),
	[type] varchar(128),
	[length] smallint,
	[precision] tinyint, 
	[scale] tinyint,
	[nullable] bit
)
WITH ( HEAP , DISTRIBUTION = ROUND_ROBIN )

-- Set up to process all tables in the defined source schema
insert into #tables
select row_number() over (order by tb.name), object_id, tb.name 
from sys.tables tb join sys.schemas s on (tb.schema_id=s.schema_id) 
where s.name = @sourceschema

select @trows = count(*) from #tables

--select * from #tables

-- initial cleanup of any previous run - if an external table still exists, you will have to drop it first
if exists(select * from sys.external_data_sources where name='AzureStorage2')
	drop external data source AzureStorage2

select @objectid=objectid, @table=[table] from #tables where rowid=@trow

-- create the external data source (once - since all files are in "subfolders")
select @cmd = 'CREATE EXTERNAL DATA SOURCE AzureStorage2 WITH (TYPE = HADOOP, LOCATION = ''wasbs://edodwdatastore@' + @blobstore + ''', CREDENTIAL = AzureStorageCredential);'
print @cmd
exec(@cmd)

while (@trow <= @trows)
 begin
	select @start = getdate()	-- save start time
	print '---------------------- ' + @targetschema + '.' + @table + ' ----------------------'

	-- clear all rows in columns temp table (for previous table)
	truncate table #columns

	-- get all the column definitions for the target table
	insert into #columns
	select c.column_id, c.[name], t.[name], c.max_length, c.[precision], c.scale, c.is_nullable 
	from sys.columns c 
		join sys.types t on (c.user_type_id=t.user_type_id) 
	where object_id = @objectid 
	order by c.column_id
	
	-- build external table definition
	select @cmd = 'CREATE EXTERNAL TABLE [ASB].[' + @table + '] (' 

	-- process each column for the target table
	select @crows = count(*) from #columns
	select @crow = 1
	select @colid = colid, @column = [column], @type = [type], @length = [length], @precision = [precision], @scale = [scale], @nullable = [nullable] from #columns where colid=@crow
	while (@crow <= @crows)
	 begin
		if (@colid <> 1) select @cmd = @cmd + ','
		select @cmd = @cmd + '[' + @column + '] ' + case when @type in ('nvarchar', 'nchar') then 'nvarchar' else 'varchar' end + '(' + 
															case when @type in ('decimal', 'numeric', 'bigint', 'real', 'float', 'money') then '35'		
																 when @type in ('tinyint', 'smallint', 'int', 'smallmoney') then '14' 
																 when @type in ('bit', 'tinyint', 'smallint') then  '6'
																 when @type in ('char', 'varchar', 'nchar', 'nvarchar', 'binary', 'varbinary') then case when @length = -1 then 'MAX' when @length < 6 then '10' when @length > 3980 and left(@type,1)='n' then '4000' when @length > 7980 then '8000' else cast(@length+20 as varchar(5)) end -- handle null and add quotes (& embedded quotes)
																 when @type = 'uniqueidentifier' then '38'
																 else '50' end + ') NULL'		-- dates and times @ 50 - image, text, xml, hierarchy and spatial data types not supported on DW
		select @crow = @crow + 1
		select @colid = colid, @column = [column], @type = [type], @length = [length], @precision = [precision], @scale = [scale], @nullable = [nullable] from #columns where colid=@crow
	 end
	select @cmd = @cmd + ') WITH ( LOCATION=''/' + @schema + '/' + @table + '/'', DATA_SOURCE = AzureStorage2, FILE_FORMAT = TextFileFormat, REJECT_TYPE = VALUE, REJECT_VALUE = 0 );'
	declare @i int = 1
	while (@i < len(@cmd))
	 begin
		print substring(@cmd, @i, 1000)		-- statements can exceed the capacity of a single print
		select @i = @i + 1000
	 end
	print ''	
	exec(@cmd)

	-- get the distribution mechanism and column for the target table
	select @distcol='', @disttype=distribution_policy_desc from sys.pdw_table_distribution_properties where object_id=@objectid
	select @distcol=c.[name] from sys.pdw_column_distribution_properties d join sys.columns c on (d.object_id=c.object_id and d.column_id=c.column_id) where d.[object_id]=@objectid and distribution_ordinal=1

	-- remove target table if it already exists
	if exists(select * from sys.tables t join sys.schemas s on (t.schema_id=s.schema_id) where s.[name] = @targetschema and t.[name]=@table)
	 begin
		select @cmd = 'DROP TABLE [' + @targetschema + '].[' + @table + ']'
		exec(@cmd)
	 end

	-- build CTAS statement - looping through all of the columns to do a cast to the appropriate data type
	select @cmd = 'CREATE TABLE [' + @targetschema + '].[' + @table + '] WITH (DISTRIBUTION = '+ case when ISNULL(@disttype, '') = '' then 'HEAP' else @disttype end + case when @distcol != '' then '([' + @distcol + '])' else '' end + ') AS SELECT '
	select @crow = 1
	select @colid = colid, @column = [column], @type = [type], @length = [length], @precision = [precision], @scale = [scale], @nullable = [nullable] from #columns where colid=@crow
	while (@crow <= @crows)
	 begin
		select @colstr = 'substring(['+@column+'], 2, LEN(['+@column+'])-2)'	-- remove lead and tail quotes
		if (@colid <> 1) select @cmd = @cmd + ', '
		if (@nullable = 0)														-- if this column is not nullable we have to give SQL DW the hint to make it NOT NULL - in theory we should error if there is a text value of null in the field, but that is just more code...
			select @cmd = @cmd + 'ISNULL(('
		if @type in ('char', 'varchar', 'nchar', 'nvarchar')  -- remove escaped quotes and replace special line end characters with line feed
			select @cmd = @cmd + 'case when [' + @column + '] = ''"null"'' then null else cast(replace(replace(replace(' + @colstr + ', ''\"'', ''"''), char(31), char(10)), char(30), char(13)) as '+ @type +'('+ case when @length=-1 then 'max' else cast(@length as varchar(10)) end +')) end' + case when @nullable=0 then '), '''')' else '' end
		else if @type in ('numeric', 'decimal')
			select @cmd = @cmd + 'case when [' + @column + '] = ''"null"'' then null else cast(' + @colstr + ' as ' + @type + '(' + cast(@precision as varchar(3)) + ',' + cast(@scale as varchar(3)) + ')) end' + case when @nullable=0 then '), 0.)' else '' end
		else if @type in ('bigint', 'real', 'float', 'money', 'int', 'smallmoney', 'bit', 'tinyint', 'smallint')
			select @cmd = @cmd + 'case when [' + @column + '] = ''"null"'' then null else cast(' + @colstr + ' as ' + @type + ') end' + case when @nullable=0 then '), 0)' else '' end
		else if @type in ('datetime', 'smalldatetime', 'date')
			select @cmd = @cmd + 'case when [' + @column + '] = ''"null"'' then null when left(['+@column+'], 5) < ''"1753'' then cast(''1753-01-01 00:00:00'' as ' + @type + ') else cast(substring(' + @colstr + ', 1, (case when CHARINDEX(''.'', ' + @column + ') != 0 then CHARINDEX(''.'', ' + @column + ') else len(' + @column + ') end)-2) as ' + @type + ') end' + case when @nullable=0 then '), cast(''1753-01-01 00:00:00'' as ' + @type + '))' else '' end
		else if @type = 'date'
			select @cmd = @cmd + 'case when [' + @column + '] = ''"null"'' then null when left(['+@column+'], 5) < ''"0001'' then cast(''0001-01-01'' as date) else cast(' + @colstr + ' as date) end' + case when @nullable=0 then '), cast(''0001-01-01'' as date))' else '' end
		else if @type = 'datetime2'
			select @cmd = @cmd + 'case when [' + @column + '] = ''"null"'' then null when left(['+@column+'], 5) < ''"0001'' then cast(''0001-01-01 00:00:00'' as datetime2(' + cast(@scale as varchar(3)) + ')) else cast(' + @colstr + ' as datetime2(' +  cast(@scale as varchar(3)) + ')) end' + case when @nullable=0 then '), cast(''0001-01-01 00:00:00'' as datetime2(' + @precision + ')))' else '' end
		else if @type = 'uniqueidentifier'
			select @cmd = @cmd + 'case when [' + @column + '] = ''"null"'' then null else cast(' + @colstr + ' as ' + @type + ') end' + case when @nullable=0 then '), cast(''00000000-0000-0000-0000-000000000000'' as uniqueidentifier))' else '' end
		else -- not sure any data types are left - if so, you need a null value for 'not null' instead of the 0
			select @cmd = @cmd + 'case when [' + @column + '] = ''"null"'' then null else cast(' + @colstr + ' as ' + @type + ') end' + case when @nullable=0 then '), 0)' else '' end
		select @cmd = @cmd + ' as ''' + @column + ''''		-- add column name
		select @crow = @crow + 1
		select @colid = colid, @column = [column], @type = [type], @length = [length], @precision = [precision], @scale = [scale], @nullable = [nullable] from #columns where colid=@crow
	 end
	select @cmd = @cmd + ' FROM [ASB].[' + @table + '] OPTION (LABEL = ''CTAS : Load [' + @targetschema + '].[' + @table + ']'');'
	select @i = 1
	while (@i < len(@cmd))
	 begin
		print substring(@cmd, @i, 1000)
		select @i = @i + 1000
	 end
	print ''	
	exec(@cmd)

	-- Cleanup external objects
	select @cmd = 'DROP EXTERNAL TABLE [ASB].[' + @table + ']'
	print @cmd
	exec(@cmd)

	-- Output row count and elapsed load time for the current table
	select @cmd = 'select COUNT_BIG(*) as ''Rows in [' + @targetschema + '].[' + @table + ']'', ' + cast(datediff(s, @start, getdate())/60.0 as varchar(40)) + ' as ''Minutes to Load'' from [' + @targetschema + '].[' + @table + ']'
	exec(@cmd)

	-- Increment to the next table
	select @trow = @trow + 1
	select @objectid=objectid, @table=[table] from #tables where rowid=@trow
 end
drop table #tables
drop table #columns
